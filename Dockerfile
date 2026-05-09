# syntax=docker/dockerfile:1.7
#
# Reusable dev image for the dbt_duckdb_sqlserver project.
#
# Contains everything needed to run the full pipeline without any host-level
# setup — no brew, no Command-Line-Tools Python, no platform-specific Flyway
# tarball, no dbt-sqlserver resolution dance. Mirrors the host pins:
#   - Python 3.12
#   - duckdb<1.5 (so the `mssql` community extension resolves)
#   - dbt-sqlserver==1.9.0 (compatible with dbt-core 1.11.x)
#
# Designed to be used via docker-compose (see the `dbt-runner` service) or
# VS Code devcontainers (see .devcontainer/devcontainer.json). Can also be
# used standalone: `docker build -t dbt-fidemo . && docker run --rm -it …`.

FROM python:3.14-slim-bookworm

ARG TARGETARCH
ARG FLYWAY_VERSION=10.22.0

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:/opt/flyway:/opt/mssql-tools18/bin:${PATH}"

# ---- System dependencies -------------------------------------------------
# * ca-certificates, curl, gnupg   — prerequisites for the MS apt repo
# * openjdk-17-jre-headless        — required by the Flyway CLI
# * unixodbc / msodbcsql18         — ODBC stack for dbt-sqlserver (pyodbc)
# * mssql-tools18                  — provides sqlcmd (used by the Makefile)
# * git                            — dbt deps resolution for git packages
# * build-essential                — some pip packages still need a compiler
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        git \
        openjdk-17-jre-headless \
        build-essential \
        unixodbc-dev \
    # Microsoft's packaged helper installs the correct signing key +
    # sources.list entry in a single step. More reliable than the
    # classic `curl | gpg --dearmor` approach, which currently trips
    # on a key-path mismatch (NO_PUBKEY EB3E94ADBE1229CF).
    && curl -fsSL -o /tmp/packages-microsoft-prod.deb \
         https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && rm /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends \
        msodbcsql18 \
        mssql-tools18 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ---- Flyway CLI (noarch — uses system Java) ------------------------------
# Maven Central ships a `linux-x64` and a noarch `flyway-commandline-VER.tar.gz`
# but NOT a `linux-arm64` archive for 10.x (verified through 10.22.0). The noarch tarball works on any
# CPU because it defers to the system JRE installed above. Simpler and keeps
# the image reproducible across amd64/arm64 builds.
RUN set -eux; \
    curl -fsSL \
        "https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/${FLYWAY_VERSION}/flyway-commandline-${FLYWAY_VERSION}.tar.gz" \
        -o /tmp/flyway.tar.gz; \
    mkdir -p /opt/flyway; \
    tar -xzf /tmp/flyway.tar.gz -C /opt/flyway --strip-components=1; \
    rm /tmp/flyway.tar.gz; \
    /opt/flyway/flyway --version

# ---- uv + Python deps -----------------------------------------------------
# uv installs into /usr/local/bin; using it to create an isolated venv at
# /opt/venv keeps the system Python pristine and the install reproducible.
COPY --from=ghcr.io/astral-sh/uv:0.11.12 /uv /usr/local/bin/uv

WORKDIR /workspace
COPY requirements.txt /tmp/requirements.txt

RUN uv venv /opt/venv --python 3.12 \
    && uv pip install --python /opt/venv/bin/python -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

# ---- Runtime defaults ----------------------------------------------------
# Env vars are set here as defaults; docker-compose / devcontainer overrides
# these to match the compose network (mssql-dbt-duckdb:1433 etc.).
ENV MSSQL_HOST=mssql-dbt-duckdb \
    MSSQL_PORT=1433 \
    MSSQL_DB=fidemo \
    MSSQL_USER=fidemo_loader \
    MSSQL_PWD=StrongPassword456! \
    MINIO_ENDPOINT_HOSTPORT=minio-dbt-duckdb:9000 \
    MINIO_ACCESS_KEY=minioadmin \
    MINIO_SECRET_KEY=minioadminpassword \
    MSSQL_DUCKDB_CONN="Server=mssql-dbt-duckdb,1433;Database=fidemo;User Id=fidemo_loader;Password=StrongPassword456!;TrustServerCertificate=true"

# Keep the container alive so `docker exec` / devcontainer can attach.
CMD ["sleep", "infinity"]
