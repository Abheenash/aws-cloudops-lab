#!/usr/bin/env python3
"""Patch-compliance report for the AWS Cloud Ops Lab.

Queries SSM Patch Manager for the `cops-app` patch group, summarizes each
managed instance's compliant vs. non-compliant patch counts, prints a table,
and exits non-zero if any instance falls below a minimum compliance threshold.

Backs the patch-compliance roadmap item.

Usage:
    python3 patch_compliance_report.py [--region us-east-1] \
        [--patch-group cops-app] [--min-compliant 100]

Required IAM permissions:
    ssm:DescribeInstancePatchStatesForPatchGroup
    ssm:DescribeInstancePatchStates   (fallback path)
"""

import argparse
import sys

import boto3
from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError

DEFAULT_REGION = "us-east-1"
DEFAULT_PATCH_GROUP = "cops-app"


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--region",
        default=DEFAULT_REGION,
        help="AWS region (default: %(default)s)",
    )
    parser.add_argument(
        "--patch-group",
        default=DEFAULT_PATCH_GROUP,
        help="SSM Patch Group tag value (default: %(default)s)",
    )
    parser.add_argument(
        "--min-compliant",
        type=float,
        default=100.0,
        help="Minimum per-instance compliance percentage before failing "
        "(default: %(default)s)",
    )
    return parser.parse_args()


def get_patch_states(ssm, patch_group):
    """Return the list of instance patch-state dicts for a patch group.

    Uses a paginator over describe_instance_patch_states_for_patch_group so the
    report is correct even with more instances than a single page returns.
    """
    states = []
    paginator = ssm.get_paginator(
        "describe_instance_patch_states_for_patch_group"
    )
    for page in paginator.paginate(PatchGroup=patch_group):
        states.extend(page.get("InstancePatchStates", []))
    return states


def compliance_pct(state):
    """Compute a compliance percentage for a single instance patch state.

    Compliant = InstalledCount + InstalledOtherCount (patches present that the
    baseline approves or that are not managed by the baseline).
    Non-compliant = anything missing, failed, or pending reboot.
    """
    installed = state.get("InstalledCount", 0)
    installed_other = state.get("InstalledOtherCount", 0)
    missing = state.get("MissingCount", 0)
    failed = state.get("FailedCount", 0)
    pending_reboot = state.get("InstalledPendingRebootCount", 0)

    compliant = installed + installed_other
    non_compliant = missing + failed + pending_reboot
    total = compliant + non_compliant

    # No patches evaluated yet -> treat as 100% so a freshly-scanned, clean
    # instance is not falsely flagged. Missing/failed drive the score down.
    if total == 0:
        return 100.0, compliant, non_compliant
    return (compliant / total) * 100.0, compliant, non_compliant


def main():
    args = parse_args()

    try:
        ssm = boto3.client("ssm", region_name=args.region)
        states = get_patch_states(ssm, args.patch_group)
    except NoCredentialsError:
        print("ERROR: No AWS credentials found. Configure a profile or role.",
              file=sys.stderr)
        return 2
    except (ClientError, BotoCoreError) as exc:
        print(f"ERROR: Failed to query SSM Patch Manager: {exc}",
              file=sys.stderr)
        return 2

    if not states:
        print(f"No managed instances found for patch group "
              f"'{args.patch_group}' in {args.region}.")
        print("Nothing to report (are the instances SSM-managed and scanned?).")
        # Empty inventory is not a compliance failure; it is an operational
        # gap the operator should notice, so exit 0 but make it visible.
        return 0

    # Header
    print(f"\nPatch compliance report — patch group '{args.patch_group}' "
          f"({args.region})")
    print("=" * 78)
    header = (f"{'Instance ID':<20} {'Compliant':>9} {'Non-compliant':>13} "
              f"{'Pct':>7}  {'Baseline overall':<16}")
    print(header)
    print("-" * 78)

    below_threshold = []
    for state in sorted(states, key=lambda s: s.get("InstanceId", "")):
        instance_id = state.get("InstanceId", "unknown")
        overall = state.get("Operation", "") or "-"
        # OperationEndTime / compliance summary come from the last scan.
        pct, compliant, non_compliant = compliance_pct(state)
        flag = "" if pct >= args.min_compliant else "  <-- BELOW THRESHOLD"
        print(f"{instance_id:<20} {compliant:>9} {non_compliant:>13} "
              f"{pct:>6.1f}%  {overall:<16}{flag}")
        if pct < args.min_compliant:
            below_threshold.append((instance_id, pct))

    print("-" * 78)
    print(f"Instances: {len(states)}  |  "
          f"Threshold: {args.min_compliant:.1f}%  |  "
          f"Below threshold: {len(below_threshold)}")

    if below_threshold:
        print("\nRESULT: NON-COMPLIANT", file=sys.stderr)
        for instance_id, pct in below_threshold:
            print(f"  - {instance_id}: {pct:.1f}%", file=sys.stderr)
        return 1

    print("\nRESULT: COMPLIANT — all instances meet the threshold.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
