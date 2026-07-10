# Operational automation

Python 3 / Boto3, Lambda, EventBridge, and SSM automation for the AWS Cloud
Ops Lab — patch-compliance reporting, resource-health checks, and non-prod
scheduling.

> Evidence is added here as drills are completed. See the [roadmap](../README.md#roadmap).

## Shared spec

Prefix `cops`, region `us-east-1`:

- App tier: EC2 Auto Scaling Group `cops-app-asg` (instances tagged
  `Patch Group = cops-app`, SSM-managed)
- ALB `cops-alb` with target group `cops-app-tg`
- RDS `cops-db`
- CloudWatch alarms named `cops-*`, SNS topic `cops-alerts`

## Prerequisites

- Python 3.9+ and Boto3: `pip install boto3`
- AWS credentials resolvable by Boto3 (env vars, a shared profile, or an
  attached IAM role). Nothing is hardcoded; region defaults to `us-east-1`
  and every CLI script accepts `--region`.

## Scripts

### `patch_compliance_report.py`

Queries SSM Patch Manager for the `cops-app` patch group, summarizes each
managed instance's compliant vs. non-compliant patch counts, prints a table,
and **exits non-zero if any instance is below `--min-compliant`** (default
100%). Backs the patch-compliance roadmap item.

IAM: `ssm:DescribeInstancePatchStatesForPatchGroup`,
`ssm:DescribeInstancePatchStates`.

```bash
# Default: cops-app patch group, us-east-1, fail below 100% compliance
python3 patch_compliance_report.py

# Loosen the gate and target another region
python3 patch_compliance_report.py --min-compliant 95 --region us-west-2

# Override the patch group tag value
python3 patch_compliance_report.py --patch-group cops-app
```

Exit codes: `0` compliant / no instances, `1` at least one instance below
threshold, `2` AWS/credential error.

### `resource_health_check.py`

Prints a one-screen health summary — ALB target health for `cops-app-tg`, RDS
`cops-db` status, and the state of every `cops-*` CloudWatch alarm — and
**exits non-zero if anything is unhealthy or in ALARM**.

IAM: `elasticloadbalancing:DescribeTargetGroups`,
`elasticloadbalancing:DescribeTargetHealth`, `rds:DescribeDBInstances`,
`cloudwatch:DescribeAlarms`.

```bash
python3 resource_health_check.py
python3 resource_health_check.py --region us-east-1
```

Exit codes: `0` all healthy, `1` something unhealthy / an alarm in ALARM,
`2` AWS/credential error.

### `nonprod_scheduler.py`

AWS Lambda handler `handler(event, context)` that scales `cops-app-asg` to save
non-prod cost:

- `event["action"] == "stop"` -> set ASG min & desired to `0`
- `event["action"] == "start"` -> set ASG min & desired to `2`
  (override with the `START_CAPACITY` env var)

Backs the non-prod scheduling / cost roadmap item. The module docstring
contains the two ready-to-run `aws scheduler create-schedule` commands
(stop 20:00, start 08:00, weekdays) to wire it up with EventBridge Scheduler.

IAM (Lambda execution role): `autoscaling:UpdateAutoScalingGroup`
(plus `autoscaling:DescribeAutoScalingGroups` if you extend the logging).

Deploy: package as a Lambda with handler `nonprod_scheduler.handler`, runtime
Python 3.x. Two EventBridge Scheduler schedules pass `{"action":"stop"}` and
`{"action":"start"}` as the target input — see the docstring.

```bash
# Local smoke test (needs credentials + AWS_REGION in the environment):
AWS_REGION=us-east-1 python3 nonprod_scheduler.py stop
AWS_REGION=us-east-1 python3 nonprod_scheduler.py start
```

## Note on output

Any example output in this repo is illustrative. Real run evidence (with
timestamps) is captured separately as drills are completed.
