# Drill 02 — Latency degradation

**Status:** PLAN (not yet executed) · **Region:** us-east-1 · **Prefix:** cops

## Hypothesis

If the app adds ~5s of artificial latency on every request (via the `/opt/app/FORCE_SLOW` toggle) on both `cops-app-asg` instances, then ALB `TargetResponseTime` p95 will exceed 1.5s, and alarm `cops-alb-latency-p95` will trip after the sustained condition (p95 > 1.5s for 3 consecutive 60s periods). Composite `cops-service-health` follows. Requests should still return 200 (slow, not failed), so `cops-alb-5xx` should stay OK — this isolates a latency signal.

## Blast radius & safety

- Lab-only; no customer traffic.
- Reversible via a single file deletion per instance; no redeploy or config change.
- Added latency (~5s) is well under typical ALB idle timeout, so requests complete rather than error.
- No infra mutation. Cost impact negligible.

## Inject

```bash
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
  --region us-east-1 --auto-scaling-group-names cops-app-asg \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" \
  --output text)
echo "Targeting: $INSTANCE_IDS"

aws ssm send-command \
  --region us-east-1 \
  --document-name "AWS-RunShellScript" \
  --targets "Key=InstanceIds,Values=$(echo $INSTANCE_IDS | tr ' ' ',')" \
  --comment "DRILL 02 inject FORCE_SLOW" \
  --parameters 'commands=["touch /opt/app/FORCE_SLOW"]'
```

Drive steady traffic for at least ~4 minutes so the alarm's 3× 60s evaluation window can accumulate:

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --region us-east-1 \
  --names cops-alb --query "LoadBalancers[0].DNSName" --output text)
for i in $(seq 1 240); do curl -s -o /dev/null -w "%{time_total}s\n" "http://$ALB_DNS/"; done
```

## Expected detection (hypothesis — not a measured result)

- **`cops-alb-latency-p95`** → ALARM. `TargetResponseTime` p95 jumps from sub-second to ~5s. The alarm requires the breach to hold for 3 consecutive 60s periods, so expect ALARM roughly ~3 minutes after sustained slow traffic begins. Direction: **up**.
- **`cops-service-health`** (composite) → ALARM after the child.
- SNS `cops-alerts` delivers a notification.
- `cops-alb-5xx` should **stay OK** (requests succeed, just slow). If 5xx appears, note whether latency is pushing requests into timeouts — a finding.

## Observations — fill after execution

| Field | Value |
|-------|-------|
| Date/time injected (UTC) | `<fill after run>` |
| Observed p95 `TargetResponseTime` at peak | `<fill after run>` |
| Time `cops-alb-latency-p95` entered ALARM | `<fill after run>` |
| Detection latency (inject → alarm) | `<fill after run>` |
| Alarms that fired | `<fill after run>` |
| Composite state change time | `<fill after run>` |
| SNS notification received? | `<fill after run>` |
| Dashboard evidence (screenshot / link) | `<fill after run>` |
| Did `cops-alb-5xx` stay OK? | `<fill after run>` |
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
  --comment "DRILL 02 recover remove FORCE_SLOW" \
  --parameters 'commands=["rm -f /opt/app/FORCE_SLOW"]'
```

Confirm recovery: p95 returns below 1.5s, `cops-alb-latency-p95` and composite return to OK, `curl` timings return to baseline.

## Prevent / follow-up

- Validate the p95 threshold reflects a real SLO; document the target.
- Add a Logs Insights query for slow-request attribution (endpoint / downstream call).
- Consider whether the 3×60s window is fast enough for the SLO, or too flappy — tune based on the drill.
- Confirm ALB idle timeout > worst-case latency so slow requests don't silently 5xx.

## RCA

After running, complete a write-up using [RCA-TEMPLATE.md](RCA-TEMPLATE.md).
