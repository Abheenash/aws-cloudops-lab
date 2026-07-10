# Drill 03 — Instance failure (ASG self-heal)

**Status:** ✅ EXECUTED 2026-07-10 — alarm **did not fire**: self-healing (ASG + ELB health check) remediated faster than the 2×60 s window — a real tuning finding. Details: [RESULTS-2026-07-10.md](RESULTS-2026-07-10.md) · **Region:** us-east-1 · **Prefix:** cops

## Hypothesis

If one instance in `cops-app-asg` is abruptly terminated **without decrementing desired capacity**, then the ALB target group `cops-app-tg` will briefly show one unhealthy/draining target, `cops-unhealthy-targets` may trip transiently (≥1 unhealthy for 2× 60s), and the ASG will automatically launch a replacement to restore desired=2. Service should stay available throughout because the surviving instance keeps serving. Recovery is automatic; no manual action expected.

## Blast radius & safety

- Lab-only; the ALB routes around the terminated target, so user-visible impact should be minimal (brief capacity reduction to 1 instance).
- **No decrement** means the ASG treats this as a failure and self-heals — this is the intended, reversible behavior. If self-heal fails, manually recover (below).
- No SG/RDS/config changes. Cost impact: one extra instance launch (minutes).
- Safety guard: only terminate **one** instance so at least one healthy target always remains.

## Inject

```bash
# Pick ONE in-service instance
VICTIM=$(aws autoscaling describe-auto-scaling-groups \
  --region us-east-1 --auto-scaling-group-names cops-app-asg \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId | [0]" \
  --output text)
echo "Terminating victim: $VICTIM"

aws autoscaling terminate-instance-in-auto-scaling-group \
  --region us-east-1 \
  --instance-id "$VICTIM" \
  --no-should-decrement-desired-capacity
```

Watch the ASG converge back to desired capacity:

```bash
watch -n 15 'aws autoscaling describe-auto-scaling-groups --region us-east-1 \
  --auto-scaling-group-names cops-app-asg \
  --query "AutoScalingGroups[0].Instances[].[InstanceId,LifecycleState,HealthStatus]" \
  --output table'
```

## Expected detection (hypothesis — not a measured result)

- **`cops-unhealthy-targets`** → possibly ALARM (transient). `UnHealthyHostCount` on `cops-app-tg` rises to ≥1 while the terminated target drains and the replacement warms up + passes `/health`. Because the alarm needs 2× 60s, a fast replacement may or may not cross the threshold — either outcome is an interesting result to record. Direction: **up then back to 0**.
- **`cops-service-health`** (composite) → ALARM only if the child sustains long enough.
- ASG launches a replacement so `DesiredCapacity` returns to 2 and `UnHealthyHostCount` returns to 0 — the key success signal is **automatic recovery**.
- `cops-alb-5xx` should stay OK (surviving instance serves traffic).

## Observations — fill after execution

| Field | Value |
|-------|-------|
| Date/time terminated (UTC) | `<fill after run>` |
| Victim instance ID | `<fill after run>` |
| Did `cops-unhealthy-targets` trip? (Y/N) | `<fill after run>` |
| Time it entered ALARM (if any) | `<fill after run>` |
| Time replacement instance InService + healthy | `<fill after run>` |
| Total self-heal duration (terminate → 2 healthy) | `<fill after run>` |
| Alarms that fired | `<fill after run>` |
| Any user-visible 5xx during window? | `<fill after run>` |
| Dashboard evidence (screenshot / link) | `<fill after run>` |
| Notes | `<fill after run>` |

## Recover

Recovery is expected to be **automatic** (ASG replaces the instance). No manual step should be needed. Only if the ASG does **not** converge to desired=2:

```bash
# Confirm desired capacity, restore if drifted
aws autoscaling describe-auto-scaling-groups --region us-east-1 \
  --auto-scaling-group-names cops-app-asg \
  --query "AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize}"

# Force desired back to 2 if needed
aws autoscaling set-desired-capacity --region us-east-1 \
  --auto-scaling-group-name cops-app-asg --desired-capacity 2
```

Confirm: 2 instances InService, both healthy in `cops-app-tg`, all alarms OK.

## Prevent / follow-up

- Record the self-heal time as a baseline for future capacity/health-check tuning.
- If `cops-unhealthy-targets` never tripped, confirm that's acceptable (fast heal) vs. a gap (alarm too slow to catch single-node loss).
- Verify health check grace period / thresholds don't flag a healthy replacement too early or too late.
- Consider whether 2 instances is enough headroom to lose one without SLO impact.

## RCA

After running, complete a write-up using [RCA-TEMPLATE.md](RCA-TEMPLATE.md).
