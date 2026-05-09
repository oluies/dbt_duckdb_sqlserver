#!/usr/bin/env python3
"""
Verify the fidemo pipeline by querying every layer (raw → bronze[×2] →
silver landing[×2] → rejects → SCD2[×2]) from a single DuckDB session and
cross-checking counts / row lineage.

Uses:
  - httpfs                 for MinIO reads (raw CSV + bronze Parquet)
  - mssql community ext    for SQL Server attach (silver + SCD2)
  - ducklake + sqlite      for the DuckLake bronze attach

Renders scripts/duckdb_init.sql.template with env vars (so the same code
works on host → localhost:1433/9000 and in container → compose service
names). Prints markdown-style tables.

Typical use:
  python scripts/verify_pipeline.py --summary
  python scripts/verify_pipeline.py --peorgnr 161020159248
  python scripts/verify_pipeline.py --integrity
  python scripts/verify_pipeline.py --all         # default if no flag
  python scripts/verify_pipeline.py --emit-init   # just print rendered init SQL
                                                 # (useful for piping to harlequin -f /tmp/…)

Exit codes:
  0   all checks pass
  1   integrity report returned any rows (pipeline inconsistency detected)
  2   environment / connection problem
"""
from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path
from string import Template

SCRIPTS = Path(__file__).resolve().parent
TEMPLATE = SCRIPTS / "duckdb_init.sql.template"
SQL_FILE = SCRIPTS / "verify_pipeline.sql"
PROJECT_ROOT = SCRIPTS.parent


# ---------------------------------------------------------------------------
# Environment → rendered init SQL
# ---------------------------------------------------------------------------

DEFAULTS_HOST = {
    "MSSQL_HOST": "localhost",
    "MSSQL_PORT": "1433",
    "MSSQL_DB": "fidemo",
    "MSSQL_USER": "fidemo_loader",
    "MSSQL_PWD": "StrongPassword456!",
    "MINIO_ENDPOINT_HOSTPORT": "localhost:9000",
    "MINIO_ACCESS_KEY": "minioadmin",
    "MINIO_SECRET_KEY": "minioadminpassword",
    "DUCKLAKE_CATALOG_PATH": str(PROJECT_ROOT / "fidemo" / "ducklake_catalog.sqlite"),
}
DEFAULTS_CONTAINER = {
    **DEFAULTS_HOST,
    "MSSQL_HOST": "mssql-dbt-duckdb",
    "MINIO_ENDPOINT_HOSTPORT": "minio-dbt-duckdb:9000",
    "DUCKLAKE_CATALOG_PATH": "/workspace/fidemo/ducklake_catalog.sqlite",
}


def resolve_env(mode: str) -> dict[str, str]:
    """Pick defaults for host|container|auto, then overlay environment vars."""
    if mode == "auto":
        # crude but effective: "in a container" usually means
        # /.dockerenv exists or $DOCKER_CONTAINER / $CONTAINER is set.
        in_container = (
            Path("/.dockerenv").exists()
            or os.environ.get("CONTAINER")
            or os.environ.get("DOCKER_CONTAINER")
        )
        mode = "container" if in_container else "host"
    base = DEFAULTS_CONTAINER if mode == "container" else DEFAULTS_HOST
    return {k: os.environ.get(k, default) for k, default in base.items()}


def render_init(env: dict[str, str]) -> str:
    return Template(TEMPLATE.read_text()).safe_substitute(env)


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------

import re


def _extract_block(sql_text: str, n: int) -> str:
    m = re.search(
        rf"-- >>>REPORT-{n}-BEGIN\s*(.*?)\s*-- >>>REPORT-{n}-END",
        sql_text,
        flags=re.DOTALL,
    )
    if not m:
        raise RuntimeError(f"could not find REPORT-{n} block in {SQL_FILE}")
    return m.group(1).strip()


def _print_table(rel, *, title: str | None = None) -> list[tuple]:
    """rel is a duckdb.DuckDBPyRelation. Returns rows (for callers that care)."""
    rows = rel.fetchall()
    cols = [c for c in rel.columns]
    widths = [
        max(len(c), max((len(str(r[i])) for r in rows), default=0))
        for i, c in enumerate(cols)
    ]
    if title:
        print(f"\n### {title}\n")
    print("| " + " | ".join(c.ljust(w) for c, w in zip(cols, widths)) + " |")
    print("|-" + "-|-".join("-" * w for w in widths) + "-|")
    for r in rows:
        print("| " + " | ".join(str(v).ljust(w) for v, w in zip(r, widths)) + " |")
    print()
    return rows


def report_summary(con) -> None:
    block = _extract_block(SQL_FILE.read_text(), 1)
    _print_table(con.sql(block), title="Row counts per layer")


def report_peorgnr(con, peorgnr: str | None) -> None:
    if peorgnr is None:
        # Pick an interesting peorgnr — one with >1 SCD2 version; else any.
        row = con.execute(
            """
            SELECT COALESCE(
              (SELECT peorgnr FROM ms.finance.snap_scb_bulkfil_scd2
               GROUP BY peorgnr HAVING COUNT(*) > 1 LIMIT 1),
              (SELECT peorgnr FROM ms.finance.snap_scb_bulkfil_scd2 LIMIT 1)
            )
        """
        ).fetchone()
        peorgnr = row[0] if row and row[0] else None

    if peorgnr is None:
        print("(no peorgnr available in snapshot — skipping per-row report)")
        return

    block = _extract_block(SQL_FILE.read_text(), 2)
    block = Template(block).safe_substitute({"TARGET_PEORGNR": peorgnr})
    _print_table(con.sql(block), title=f"Cross-layer view for peorgnr = {peorgnr}")


def report_integrity(con) -> int:
    """Returns the number of problem rows (0 = healthy)."""
    block = _extract_block(SQL_FILE.read_text(), 3)
    rel = con.sql(block)
    rows = rel.fetchall()
    if not rows:
        print("\n### Integrity checks\n\n✅ no issues detected\n")
        return 0
    print("\n### Integrity checks — 🔴 problems detected\n")
    # Re-run for a fresh relation (fetchall drained the previous one).
    _print_table(con.sql(block))
    return len(rows)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument(
        "--mode",
        choices=["auto", "host", "container"],
        default="auto",
        help="Which default hostnames to use (default: auto-detect)",
    )
    p.add_argument("--summary", action="store_true", help="row counts per layer")
    p.add_argument(
        "--peorgnr",
        metavar="ID",
        nargs="?",
        const="__auto__",
        help="cross-layer view for one peorgnr (picks an interesting one if omitted)",
    )
    p.add_argument(
        "--integrity",
        action="store_true",
        help="only the integrity checks; exit 1 on problems",
    )
    p.add_argument(
        "--all",
        action="store_true",
        help="all three reports (default when no flag given)",
    )
    p.add_argument(
        "--emit-init",
        action="store_true",
        help="print the rendered init SQL (for scripts/harlequin piping) and exit",
    )
    args = p.parse_args()

    env = resolve_env(args.mode)
    init_sql = render_init(env)

    if args.emit_init:
        sys.stdout.write(init_sql)
        return 0

    try:
        import duckdb
    except ImportError:
        print(
            "❌ duckdb module not available — install via `uv pip install "
            "--python /opt/venv/bin/python duckdb`",
            file=sys.stderr,
        )
        return 2

    # Default: all three reports
    if not (args.summary or args.peorgnr or args.integrity or args.all):
        args.all = True

    con = duckdb.connect()
    try:
        con.execute(init_sql)
    except Exception as e:
        print(f"❌ init failed ({args.mode} mode):\n   {e}", file=sys.stderr)
        return 2

    exit_code = 0
    if args.summary or args.all:
        report_summary(con)
    if args.peorgnr or args.all:
        peorgnr = None if (args.peorgnr in (None, "__auto__")) else args.peorgnr
        report_peorgnr(con, peorgnr)
    if args.integrity or args.all:
        n = report_integrity(con)
        if n > 0:
            exit_code = 1
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
