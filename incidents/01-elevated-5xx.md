# Drill 01 — Elevated 5xx

**Status:** ✅ EXECUTED 2026-07-10 (live run against a real `terraform apply`, then destroyed) · **Region:** us-east-1 · **Prefix:** cops

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

## Observations — measured (run of 2026-07-10)

| Field | Value |
|-------|-------|
| Date/time injected (UTC) | **2026-07-10 17:54:15Z** (`FORCE_500` via SSM to both instances; `/` responses flipped 200→500 within ~10s) |
| Time `cops-alb-5xx` entered ALARM | **2026-07-10 17:57:12Z** (confirmed in alarm history) |
| **Detection latency (inject → alarm)** | **~2m57s (177s)** — ALB metric-publishing lag + the 60s evaluation period |
| Peak error rate | **~48 `HTTPCode_Target_5XX_Count`/min** (17:55–17:56, per `get-metric-statistics`) |
| Alarms that fired | `cops-alb-5xx` (confirmed) |
| Composite `cops-service-health` state change time | **Unconfirmed** — the alarm-history API returned no state-change item for this window; its `StateReason` did reference the child's OK transition, so it was tracking the child. See Findings. |
| SNS notification received? | No email delivered — this run used the default blank `alarm_email`, so `cops-alerts` had no subscriber (the alarm action still fired to the topic). Re-run with `alarm_email` set to verify delivery. |
| Dashboard evidence | Target-5xx per-minute: 42 / 48 / 48 / 24 across 17:54–17:57Z (`cops-golden-signals` "Errors" widget) |
| Did `cops-unhealthy-targets` stay OK? | **Yes** during the drill — it did *not* fire from `FORCE_500` (it only fired earlier, 17:47–17:48Z, while the 2nd instance was still booting). Confirms the health check is independent of the user-path failure, as designed. |
| Recovery | Fault removed 17:57:47Z → `/` returned 200 immediately, both targets healthy, Target-5xx → 0. Alarm returned to **OK at 18:06:12Z** (~8m later). |

## Findings (why we run the drill instead of assuming)

1. **Detection is real and reasonable** — 177s from fault to page. Good enough to catch a customer-impacting outage, driven mostly by ALB's ~1–3 min metric latency (not something we control) plus the single 60s evaluation window.
2. **Health-check independence confirmed.** The earlier fear — that forcing 500s would flip targets unhealthy and turn this into an ELB-503 scenario — did not happen, because `/health` is deliberately decoupled from the `FORCE_500` toggle. `cops-unhealthy-targets` stayed OK throughout the drill.
3. **Slow alarm recovery (~8m).** `HTTPCode_Target_5XX_Count` is emitted by the ALB *only when non-zero*, so after recovery the metric goes **missing**, and with `treat_missing_data = notBreaching` the alarm takes several minutes to evaluate its way back to OK. This is expected but worth knowing: "alarm cleared" lagged "service recovered" by ~8 minutes. Follow-up: accept it, or add a fast recovery signal (e.g. a healthy-request canary) if faster all-clear matters.
4. **Composite behavior unconfirmed — follow-up.** `cops-alb-5xx` (a child of `cops-service-health`) definitely fired, but I could not confirm from the history API whether the composite itself transitioned to ALARM during the window. Next run: watch `cops-service-health` live during injection to close this out.

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
