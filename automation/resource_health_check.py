#!/usr/bin/env python3
"""One-screen resource health summary for the AWS Cloud Ops Lab.

Prints, on a single screen:
  * ALB target health for target group `cops-app-tg`
  * RDS instance `cops-db` status
  * State of every CloudWatch alarm named `cops-*`

Exits non-zero if anything is unhealthy or any alarm is in ALARM state, so it
can be dropped into a cron job or CI gate.

Usage:
    python3 resource_health_check.py [--region us-east-1]

Required IAM permissions:
    elasticloadbalancing:DescribeTargetGroups
    elasticloadbalancing:DescribeTargetHealth
    rds:DescribeDBInstances
    cloudwatch:DescribeAlarms
"""

import argparse
import sys

import boto3
from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError

DEFAULT_REGION = "us-east-1"
TARGET_GROUP_NAME = "cops-app-tg"
DB_INSTANCE_ID = "cops-db"
ALARM_PREFIX = "cops-"

# RDS statuses considered healthy for a steady-state instance.
RDS_HEALTHY = {"available"}


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--region",
        default=DEFAULT_REGION,
        help="AWS region (default: %(default)s)",
    )
    return parser.parse_args()


def check_alb(elbv2):
    """Return (healthy: bool, lines: list[str]) for the ALB target group."""
    lines = []
    try:
        tg_resp = elbv2.describe_target_groups(Names=[TARGET_GROUP_NAME])
    except ClientError as exc:
        return False, [f"ALB target group '{TARGET_GROUP_NAME}': ERROR — {exc}"]

    groups = tg_resp.get("TargetGroups", [])
    if not groups:
        return False, [f"ALB target group '{TARGET_GROUP_NAME}': NOT FOUND"]

    tg_arn = groups[0]["TargetGroupArn"]
    health = elbv2.describe_target_health(TargetGroupArn=tg_arn)
    descriptions = health.get("TargetHealthDescriptions", [])

    if not descriptions:
        lines.append(f"ALB {TARGET_GROUP_NAME}: no registered targets")
        return False, lines

    healthy = True
    for desc in descriptions:
        target_id = desc.get("Target", {}).get("Id", "unknown")
        state = desc.get("TargetHealth", {}).get("State", "unknown")
        reason = desc.get("TargetHealth", {}).get("Reason", "")
        ok = state == "healthy"
        healthy = healthy and ok
        marker = "OK " if ok else "BAD"
        detail = f" ({reason})" if reason else ""
        lines.append(f"  [{marker}] {target_id}: {state}{detail}")
    header = f"ALB {TARGET_GROUP_NAME}: {len(descriptions)} target(s)"
    return healthy, [header] + lines


def check_rds(rds):
    """Return (healthy: bool, lines: list[str]) for the RDS instance."""
    try:
        resp = rds.describe_db_instances(DBInstanceIdentifier=DB_INSTANCE_ID)
    except ClientError as exc:
        # DBInstanceNotFound and permission errors both land here.
        return False, [f"RDS {DB_INSTANCE_ID}: ERROR — {exc}"]

    instances = resp.get("DBInstances", [])
    if not instances:
        return False, [f"RDS {DB_INSTANCE_ID}: NOT FOUND"]

    db = instances[0]
    status = db.get("DBInstanceStatus", "unknown")
    engine = db.get("Engine", "?")
    multi_az = db.get("MultiAZ", False)
    ok = status in RDS_HEALTHY
    marker = "OK " if ok else "BAD"
    return ok, [
        f"RDS {DB_INSTANCE_ID}: [{marker}] status={status} "
        f"engine={engine} multi_az={multi_az}"
    ]


def check_alarms(cloudwatch):
    """Return (healthy: bool, lines: list[str]) for cops-* CloudWatch alarms."""
    alarms = []
    paginator = cloudwatch.get_paginator("describe_alarms")
    try:
        for page in paginator.paginate(AlarmNamePrefix=ALARM_PREFIX):
            alarms.extend(page.get("MetricAlarms", []))
            alarms.extend(page.get("CompositeAlarms", []))
    except ClientError as exc:
        return False, [f"CloudWatch alarms '{ALARM_PREFIX}*': ERROR — {exc}"]

    if not alarms:
        return True, [f"CloudWatch alarms '{ALARM_PREFIX}*': none found"]

    lines = [f"CloudWatch alarms '{ALARM_PREFIX}*': {len(alarms)} alarm(s)"]
    healthy = True
    for alarm in sorted(alarms, key=lambda a: a.get("AlarmName", "")):
        name = alarm.get("AlarmName", "unknown")
        state = alarm.get("StateValue", "UNKNOWN")
        # ALARM is unhealthy. INSUFFICIENT_DATA is a warning but not a failure.
        in_alarm = state == "ALARM"
        healthy = healthy and not in_alarm
        marker = "BAD" if in_alarm else ("OK " if state == "OK" else "?? ")
        lines.append(f"  [{marker}] {name}: {state}")
    return healthy, lines


def main():
    args = parse_args()

    try:
        session = boto3.Session(region_name=args.region)
        elbv2 = session.client("elbv2")
        rds = session.client("rds")
        cloudwatch = session.client("cloudwatch")
    except NoCredentialsError:
        print("ERROR: No AWS credentials found. Configure a profile or role.",
              file=sys.stderr)
        return 2

    print(f"\nResource health — AWS Cloud Ops Lab ({args.region})")
    print("=" * 60)

    overall_healthy = True
    try:
        for check in (
            lambda: check_alb(elbv2),
            lambda: check_rds(rds),
            lambda: check_alarms(cloudwatch),
        ):
            healthy, lines = check()
            overall_healthy = overall_healthy and healthy
            for line in lines:
                print(line)
            print("-" * 60)
    except (BotoCoreError, ClientError) as exc:
        print(f"ERROR: AWS call failed: {exc}", file=sys.stderr)
        return 2

    if overall_healthy:
        print("OVERALL: HEALTHY")
        return 0

    print("OVERALL: UNHEALTHY", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
