# Drill 01 — Elevated 5xx

**Status:** PLAN (not yet executed) · **Region:** us-east-1 · **Prefix:** cops

## Hypothesis

If the Flask app returns HTTP 500 on every request (via the `/opt/app/FORCE_500` toggle) on both `cops-app-asg` instances, then the ALB `cops-alb` will emit `HTTPCode_Target_5XX_Count`, alarm `cops-alb-5xx` will trip (5xx Sum ≥ 3 over 60s), and the composite alarm `cops-service-health` will go into ALARM shortly after. The `/health` endpoint is expected to keep passing (the toggle affects app responses, not the health check), so targets should stay *healthy* — this isolates a pure application-error signal.

## Blast radius & safety

- Affects only this lab's app; no customer traffic.
- Fully reversible: recovery is deleting a single sentinel file on each instance — no redeploy, no state change.
- No infrastructure is mutated (no ASG, SG, or RDS changes). Instances stay in service.
- Cost impact: negligible (a few minutes of alarm/SNS activity).

## Inject

Resolve the running instance IDs for the ASG, then create the toggle file on each via SSM.

```bash
# 1. Get instance IDs currently in the ASG
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
  --region us-east-1 \
  --auto-scaling-group-names cops-app-asg \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" \
  --output text)
echo "Targeting: $INSTANCE_IDS"

# 2. Inject FORCE_500 on all instances
aws ssm send-command \
  --region us-east-1 \
  --document-name "AWS-RunShellScript" \
  --targets "Key=InstanceIds,Values=$(echo $INSTANCE_IDS | tr ' ' ',')" \
  --comment "DRILL 01 inject FORCE_500" \
  --parameters 'commands=["touch /opt/app/FORCE_500"]'
```

Generate a little traffic so the ALB has requests to fail (optional if a background poller already hits it):

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --region us-east-1 \
  --names cops-alb --query "LoadBalancers[0].DNSName" --output text)
for i in $(seq 1 60); do curl -s -o /dev/null -w "%{http_code}\n" "http://$ALB_DNS/"; sleep 1; done
```

## Expected detection (hypothesis — not a measured result)

- **`cops-alb-5xx`** → ALARM. `HTTPCode_Target_5XX_Count` (Sum) rises from ~0 to ≥ 3 within a single 60s period once traffic hits the failing app; the alarm should transition to ALARM on the first breaching period. Direction: **up**.
- **`cops-service-health`** (composite) → ALARM, following the child alarm.
- SNS `cops-alerts` should deliver a notification for the transition.
- `cops-unhealthy-targets` should **stay OK** (health check independent of the 500 toggle) — if it also trips, that's a finding worth noting.

## Observations — fill after execution

| Field | Value |
|-------|-------|
| Date/time injected (UTC) | `<fill after run>` |
| Time `cops-alb-5xx` entered ALARM | `<fill after run>` |
| Detection latency (inject → alarm) | `<fill after run>` |
| Alarms that fired | `<fill after run>` |
| Composite `cops-service-health` state change time | `<fill after run>` |
| SNS notification received? | `<fill after run>` |
| Dashboard evidence (screenshot / link) | `<fill after run>` |
| Did `cops-unhealthy-targets` stay OK? | `<fill after run>` |
| Notes | `<fill after run>` |

## Recover

```bash
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
  --region us-east-1 --auto-scaling-group-names cops-app-asg \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" \
  --output text)

aws ssm send-command \
  --region us-east-1 \
  --document-name "AWS-RunShellScript" \
  --targets "Key=InstanceIds,Values=$(echo $INSTANCE_IDS | tr ' ' ',')" \
  --comment "DRILL 01 recover remove FORCE_500" \
  --parameters 'commands=["rm -f /opt/app/FORCE_500"]'
```

Confirm recovery: 5xx count returns to ~0, `cops-alb-5xx` and `cops-service-health` return to OK, and `curl http://$ALB_DNS/` returns 200.

## Prevent / follow-up

- Confirm alarm threshold/period give timely-but-not-flappy detection; tune if the drill shows lag.
- Consider an app-level structured error log + Logs Insights query to attribute 5xx to a cause.
- Verify the composite alarm messaging in `cops-alerts` is actionable (names the failing child).
- Confirm health check truly is independent of user-path failures (defense in depth).

## RCA

After running, complete a write-up using [RCA-TEMPLATE.md](RCA-TEMPLATE.md).
