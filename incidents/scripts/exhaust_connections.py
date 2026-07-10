#!/usr/bin/env python3
"""Drill 04 helper — open N idle Postgres connections to cops-db and hold them.

Runs ON an app instance (via SSM), where psycopg2 + boto3 are already installed
and the instance role can read the RDS-managed master secret. Credentials are
fetched from Secrets Manager exactly the way the app does — no passwords on the
command line.

Usage (on the instance):
    python3 exhaust_connections.py --host <rds-endpoint> --secret-arn <arn> \
        [--dbname copsdb] [--count 120] [--hold 600] [--region us-east-1]

Bounded and self-releasing: opens at most --count connections and closes them
after --hold seconds even if left unattended.
"""
import argparse
import json
import sys
import time

import boto3
import psycopg2


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--secret-arn", required=True)
    ap.add_argument("--dbname", default="copsdb")
    ap.add_argument("--count", type=int, default=120)
    ap.add_argument("--hold", type=int, default=600)
    ap.add_argument("--region", default="us-east-1")
    args = ap.parse_args()

    sm = boto3.client("secretsmanager", region_name=args.region)
    creds = json.loads(sm.get_secret_value(SecretId=args.secret_arn)["SecretString"])

    conns = []
    for i in range(args.count):
        try:
            c = psycopg2.connect(
                host=args.host, dbname=args.dbname,
                user=creds["username"], password=creds["password"],
                connect_timeout=5,
            )
            c.autocommit = True
            c.cursor().execute("SELECT 1")
            conns.append(c)
        except Exception as e:  # noqa: BLE001 — surface where capacity runs out
            print(f"stopped opening at {i}: {e}", flush=True)
            break

    print(f"opened {len(conns)} connections; holding {args.hold}s", flush=True)
    try:
        time.sleep(args.hold)
    finally:
        for c in conns:
            try:
                c.close()
            except Exception:  # noqa: BLE001
                pass
        print("released all connections", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
