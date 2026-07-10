"""Non-prod scheduler Lambda for the AWS Cloud Ops Lab.

Scales the `cops-app-asg` Auto Scaling Group down outside business hours and
back up in the morning to cut non-prod EC2 cost. Backs the non-prod
scheduling / cost roadmap item.

The Lambda reads `event["action"]`:
    "stop"  -> set the ASG's desired and min capacity to 0
    "start" -> set the ASG's desired and min capacity back to 2

Deploy behind two EventBridge Scheduler schedules (times are UTC unless you set
ScheduleExpressionTimezone). Weekdays only:

    # Stop at 20:00 on weekdays
    aws scheduler create-schedule \
      --name cops-nonprod-stop \
      --schedule-expression "cron(0 20 ? * MON-FRI *)" \
      --schedule-expression-timezone "America/New_York" \
      --flexible-time-window '{"Mode":"OFF"}' \
      --target '{
          "Arn":"<LAMBDA_FUNCTION_ARN>",
          "RoleArn":"<SCHEDULER_INVOKE_ROLE_ARN>",
          "Input":"{\"action\":\"stop\"}"
      }'

    # Start at 08:00 on weekdays
    aws scheduler create-schedule \
      --name cops-nonprod-start \
      --schedule-expression "cron(0 8 ? * MON-FRI *)" \
      --schedule-expression-timezone "America/New_York" \
      --flexible-time-window '{"Mode":"OFF"}' \
      --target '{
          "Arn":"<LAMBDA_FUNCTION_ARN>",
          "RoleArn":"<SCHEDULER_INVOKE_ROLE_ARN>",
          "Input":"{\"action\":\"start\"}"
      }'

Required IAM permissions for the Lambda execution role:
    autoscaling:UpdateAutoScalingGroup
    autoscaling:DescribeAutoScalingGroups   (optional, used for logging)

Environment variables (all optional, defaults shown):
    ASG_NAME       cops-app-asg
    START_CAPACITY 2
    AWS_REGION     provided automatically by the Lambda runtime
"""

import os

import boto3
from botocore.exceptions import BotoCoreError, ClientError

ASG_NAME = os.environ.get("ASG_NAME", "cops-app-asg")
# Capacity restored on "start". Overridable so the same code works if the
# steady-state size ever changes.
START_CAPACITY = int(os.environ.get("START_CAPACITY", "2"))
STOP_CAPACITY = 0


def _set_capacity(asg_name, desired, minimum):
    """Update the ASG's min and desired capacity.

    Region is taken from the AWS_REGION env var that the Lambda runtime sets;
    boto3 picks it up automatically, so no region is hardcoded here.
    """
    autoscaling = boto3.client("autoscaling")
    autoscaling.update_auto_scaling_group(
        AutoScalingGroupName=asg_name,
        MinSize=minimum,
        DesiredCapacity=desired,
    )


def handler(event, context):
    """Lambda entry point.

    event: {"action": "stop" | "start"}
    Returns a small dict describing what was done (surfaced in CloudWatch Logs).
    """
    action = (event or {}).get("action", "").lower()

    if action == "stop":
        desired = minimum = STOP_CAPACITY
    elif action == "start":
        desired = minimum = START_CAPACITY
    else:
        # Fail loudly: an unknown action must not silently no-op a cost control.
        raise ValueError(
            f"Unknown action {action!r}; expected 'stop' or 'start'."
        )

    try:
        _set_capacity(ASG_NAME, desired=desired, minimum=minimum)
    except (BotoCoreError, ClientError) as exc:
        # Re-raise so Lambda marks the invocation failed and EventBridge can
        # retry / alarm on it rather than reporting a false success.
        print(f"ERROR: Failed to {action} {ASG_NAME}: {exc}")
        raise

    result = {
        "asg": ASG_NAME,
        "action": action,
        "min_size": minimum,
        "desired_capacity": desired,
    }
    print(f"Set {ASG_NAME}: min={minimum} desired={desired} (action={action})")
    return result


if __name__ == "__main__":
    # Local smoke test (requires AWS credentials + region in the environment):
    #   AWS_REGION=us-east-1 python3 nonprod_scheduler.py stop
    import sys

    _action = sys.argv[1] if len(sys.argv) > 1 else "start"
    print(handler({"action": _action}, None))
