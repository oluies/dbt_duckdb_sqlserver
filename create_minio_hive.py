import boto3
from botocore.client import Config
import datetime
import os
import re

# Matches an 8-digit date (YYYYMMDD) anywhere in the filename, optionally
# followed by a 'T' and a time component (e.g. 20251110T100709).
DATE_PATTERN = re.compile(r"(?P<year>\d{4})(?P<month>\d{2})(?P<day>\d{2})(?:T\d{6})?")


def extract_partitions(filename):
    """
    Extracts year/month/day from a filename containing a YYYYMMDD token.
    Returns None if no date can be found.
    """
    match = DATE_PATTERN.search(filename)
    if not match:
        return None
    year, month, day = match.group("year"), match.group("month"), match.group("day")
    try:
        datetime.date(int(year), int(month), int(day))
    except ValueError:
        return None
    return {"year": year, "month": month, "day": day}


def upload_file_hive(s3_client, bucket_name, base_path, partitions, local_path):
    """
    Uploads a local file to MinIO using a Hive-partitioned key layout.
    """
    partition_path = "/".join(f"{k}={v}" for k, v in partitions.items())
    file_name = os.path.basename(local_path)
    full_path = f"{base_path.strip('/')}/{partition_path}/{file_name}"
    print(f"Uploading {local_path} -> s3://{bucket_name}/{full_path}")
    with open(local_path, "rb") as fh:
        s3_client.put_object(Bucket=bucket_name, Key=full_path, Body=fh)


def main():
    print(f"--- Debug Info ---")
    print(f"Current System Time: {datetime.datetime.now()}")
    print(f"------------------")

    # Resolve endpoint from env vars so the same script works on host
    # (default localhost:9000) and inside the dbt-runner container
    # (MINIO_ENDPOINT_HOSTPORT=minio-dbt-duckdb:9000 set by docker-compose).
    minio_hostport = os.environ.get("MINIO_ENDPOINT_HOSTPORT", "localhost:9000")
    MINIO_ENDPOINT = f"http://{minio_hostport}"
    ACCESS_KEY = os.environ.get("MINIO_ACCESS_KEY", "minioadmin")
    SECRET_KEY = os.environ.get("MINIO_SECRET_KEY", "minioadminpassword")
    BUCKET_NAME = os.environ.get("MINIO_BUCKET", "informat")
    print(f"MinIO endpoint: {MINIO_ENDPOINT}  bucket: {BUCKET_NAME}")
    SEED_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "seedcsv")
    BASE_DIR = "seedcsv"

    s3_client = boto3.client(
        's3',
        endpoint_url=MINIO_ENDPOINT,
        aws_access_key_id=ACCESS_KEY,
        aws_secret_access_key=SECRET_KEY,
        config=Config(
            signature_version="s3v4",           # ← fixes SignatureDoesNotMatch
            s3={'addressing_style': 'path'}
        )
    )

    if not os.path.isdir(SEED_DIR):
        print(f"Seed directory not found: {SEED_DIR}")
        return

    uploaded = 0
    skipped = 0
    for entry in sorted(os.listdir(SEED_DIR)):
        local_path = os.path.join(SEED_DIR, entry)
        if not os.path.isfile(local_path):
            continue

        partitions = extract_partitions(entry)
        if partitions is None:
            print(f"Skipping {entry}: no YYYYMMDD date found in filename")
            skipped += 1
            continue

        try:
            upload_file_hive(s3_client, BUCKET_NAME, BASE_DIR, partitions, local_path)
            uploaded += 1
        except Exception as e:
            print(f"Error uploading {entry}: {e}")
            skipped += 1

    print(f"Done. Uploaded: {uploaded}, Skipped: {skipped}")


if __name__ == "__main__":
    main()
