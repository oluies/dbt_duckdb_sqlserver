#!/usr/bin/env python3
"""
Anonymize the entity/company NAME columns in the SCB bulk-file seed data so
the project can be safely committed. Other identifying fields (PeOrgNr,
street address, postal code, city) are preserved as-is per scope.

Replaces (deterministically by PeOrgNr — same input always produces same
output, so all rows for the same entity across deliveries get the same
pseudonym):

    Foretagsnamn   →  "DEMO AB <suffix>"      (preserved empty if originally empty)
    Namn           →  "DEMO ENTITY <suffix>"  (preserved empty if originally empty)
    COAdress       →  "C/O DEMO PERSON <suffix>"  (Swedish "care-of" addresses
                                                   typically hold a person's name)

NOT touched: PeOrgNr, Gatuadress, PostNr, PostOrt, dates, change flags,
status codes. The user opted to anonymize only name-bearing fields.

File structure (encoding, tab delimiter, 35 columns incl. trailing empty,
hive-partition compatibility) is preserved exactly.

The script is idempotent: a file whose name-bearing values all already
start with the `DEMO ` marker is detected and skipped.

Run:
    venv_dbt_duckdb/bin/python scripts/anonymize_seedcsv.py
or:
    venv_dbt_duckdb/bin/python scripts/anonymize_seedcsv.py --dry-run
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import sys
from pathlib import Path

SEEDCSV_DIR = Path(__file__).resolve().parent.parent / "seedcsv"
ENCODING = "latin-1"
DELIM = "\t"

DEMO_MARKER = "DEMO "  # used both as the pseudonym prefix and as the
# idempotency sentinel (re-running detects it)

# Columns we touch (by exact header label as it appears in the file).
# Scope: name-bearing fields only. Addresses/zips/cities preserved.
COLS_TO_REWRITE = {"Foretagsnamn", "Namn", "COAdress"}


def stable_hash(s: str, mod: int) -> int:
    """Deterministic non-cryptographic int in [0, mod) for any string."""
    h = hashlib.sha256(s.encode("utf-8")).hexdigest()
    return int(h, 16) % mod


def fake_company(original_peorgnr: str) -> str:
    return f"{DEMO_MARKER}AB {stable_hash('ftg:' + original_peorgnr, 10000):04d}"


def fake_entity(original_peorgnr: str) -> str:
    return f"{DEMO_MARKER}ENTITY {stable_hash('ent:' + original_peorgnr, 10000):04d}"


def fake_co_address(original_peorgnr: str) -> str:
    return f"{DEMO_MARKER}PERSON {stable_hash('co:' + original_peorgnr, 10000):04d}"


def is_already_anonymized(
    data_rows: list[list[str]], name_col_indices: list[int]
) -> bool:
    """True only if EVERY non-empty value in any name-bearing column already
    starts with the DEMO_MARKER. Empty values don't count either way."""
    if not data_rows:
        return False
    saw_any_name = False
    for r in data_rows:
        if not any(r):
            continue
        for col in name_col_indices:
            v = r[col].strip()
            if v:
                saw_any_name = True
                if not v.startswith(DEMO_MARKER):
                    return False
    return saw_any_name


def anonymize_row(row: list[str], idx: dict[str, int]) -> list[str]:
    """In-place rewrite of name-bearing columns, deterministic by PeOrgNr.
    Other columns are left untouched."""
    orig_peorgnr = row[idx["PeOrgNr"]]
    if not orig_peorgnr:
        return row

    if row[idx["Foretagsnamn"]].strip():
        row[idx["Foretagsnamn"]] = fake_company(orig_peorgnr)

    if row[idx["Namn"]].strip():
        row[idx["Namn"]] = fake_entity(orig_peorgnr)

    if row[idx["COAdress"]].strip():
        row[idx["COAdress"]] = fake_co_address(orig_peorgnr)

    return row


def process_file(path: Path, *, dry_run: bool) -> tuple[int, int, bool]:
    """Returns (rows_seen, rows_rewritten, skipped_already_anonymized)."""
    with path.open(encoding=ENCODING, newline="") as f:
        reader = csv.reader(f, delimiter=DELIM)
        rows = list(reader)

    if len(rows) < 2:
        return (0, 0, False)

    header = rows[0]
    data = rows[1:]

    missing = ({"PeOrgNr"} | COLS_TO_REWRITE) - set(header)
    if missing:
        print(f"  ⚠️  {path.name}: missing columns {missing}, skipping")
        return (len(data), 0, False)

    idx = {col: i for i, col in enumerate(header)}
    name_col_indices = [idx[c] for c in COLS_TO_REWRITE]

    if is_already_anonymized(data, name_col_indices):
        return (len(data), 0, True)

    rewritten = [anonymize_row(list(r), idx) for r in data]

    if dry_run:
        return (len(data), len(rewritten), False)

    with path.open("w", encoding=ENCODING, newline="") as f:
        writer = csv.writer(f, delimiter=DELIM, lineterminator="\n")
        writer.writerow(header)
        writer.writerows(rewritten)

    return (len(data), len(rewritten), False)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="don't rewrite files; just report what would change",
    )
    parser.add_argument(
        "--glob",
        default="scb_bulkfil_JE_*.txt",
        help="filename glob within seedcsv/ (default: %(default)s)",
    )
    args = parser.parse_args()

    files = sorted(SEEDCSV_DIR.glob(args.glob))
    if not files:
        print(f"no files matched {SEEDCSV_DIR}/{args.glob}", file=sys.stderr)
        return 1

    print(
        f"{'(dry-run) ' if args.dry_run else ''}"
        f"Anonymizing {len(files)} file(s) in {SEEDCSV_DIR}/"
    )
    total_rewritten = 0
    for f in files:
        seen, rewritten, skipped = process_file(f, dry_run=args.dry_run)
        if skipped:
            print(f"  ⏭  {f.name:<60} already anonymized ({seen} rows)")
        else:
            print(f"  ✓  {f.name:<60} {rewritten}/{seen} rows rewritten")
        total_rewritten += rewritten

    print(
        f"\nTotal rows rewritten: {total_rewritten}"
        f"{' (dry run, no files changed)' if args.dry_run else ''}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
