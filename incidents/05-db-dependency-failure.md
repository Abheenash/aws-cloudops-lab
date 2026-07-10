# Drill 05 — DB dependency failure (network cut)

**Status:** ✅ EXECUTED 2026-07-10 — `cops-alb-5xx` fired, **detection 166 s**; recovered by restoring the SG rule. Full results: [RESULTS-2026-07-10.md](RESULTS-2026-07-10.md) · **Region:** us-east-1 · **Prefix:** cops

## Hypothesis

If the app-ingress rule on `cops-rds-sg` (TCP 5432 from `cops-app-sg`) is temporarily removed, then app→DB connections from `cops-app-asg` will **time out** (packets dropped, not refused). Because the app hits `cops-db` on every request, the `/health` endpoint and/or user requests will fail. Expect `cops-unhealthy-targets` to trip as `/health` fails on both instances, and/or `cops-alb-5xx` as user requests error. Composite `cops-service-health` follows. This simulates a hard dependency outage / misconfigured network path. Recovery is restoring the SG rule.

## Blast radius & safety

- Lab-only. This is the most impactful drill — it takes the whole app effectively down (both instances lose the DB), so run it knowingly and briefly.
- Reversible: the exact ingress rule is captured before removal and re-added on recovery. No data touched; the DB itself is untouched and healthy.
- Removing ingress (not egress, not the instance) means a clean, single-command restore.
- **Capture the rule first** (below) so recovery is exact. Keep the drill window short.
- Cost impact: negligible.

## Inject

First capture the current SG IDs and the exact rule, then revoke it.

```bash
# Resolve SG IDs by name
RDS_SG=$(aws ec2 describe-security-groups --region us-east-1 \
  --filters Name=group-name,Values=cops-rds-sg \
  --query "SecurityGroups[0].GroupId" --output text)
APP_SG=$(aws ec2 describe-security-groups --region us-east-1 \
  --filters Name=group-name,Values=cops-app-sg \
  --query "SecurityGroups[0].GroupId" --output text)
echo "RDS_SG=$RDS_SG  APP_SG=$APP_SG"

# Capture current ingress for the record (paste into Observations)
aws ec2 describe-security-groups --region us-east-1 --group-ids "$RDS_SG" \
  --query "SecurityGroups[0].IpPermissions" --output json | tee /tmp/cops-rds-sg-ingress.json

# Remove the app -> RDS 5432 ingress rule  (DB calls will now time out)
aws ec2 revoke-security-group-ingress --region us-east-1 \
  --group-id "$RDS_SG" \
  --protocol tcp --port 5432 --source-group "$APP_SG"
```

Observe requests failing:

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --region us-east-1 \
  --names cops-alb --query "LoadBalancers[0].DNSName" --output text)
for i in $(seq 1 120); do curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" "http://$ALB_DNS/"; sleep 1; done
```

## Expected detection (hypothesis — not a measured result)

- **`cops-unhealthy-targets`** → ALARM. As `/health` (which touches the DB) times out on both instances, `UnHealthyHostCount` on `cops-app-tg` rises to ≥1 (likely 2) and holds ≥ 2× 60s. Direction: **up**.
- **`cops-alb-5xx`** → ALARM likely, from failing user requests (app returns 500 / times out) — and/or `HTTPCode_ELB_5XX` if no healthy targets remain to route to. Direction: **up**.
- **`cops-alb-latency-p95`** may also rise (requests hang until DB connect timeout) before erroring.
- **`cops-service-health`** (composite) → ALARM.
- SNS `cops-alerts` delivers notifications.
- Note: because the DB path is dropped (timeout) rather than refused, expect slow failures — request latency climbs first, then errors.

## Observations — fill after execution

| Field | Value |
|-------|-------|
| Date/time rule removed (UTC) | `<fill after run>` |
| Captured original ingress rule | `<fill after run — paste from /tmp/cops-rds-sg-ingress.json>` |
| First alarm to fire + time | `<fill after run>` |
| Did `cops-unhealthy-targets` fire? (time) | `<fill after run>` |
| Did `cops-alb-5xx` fire? (time) | `<fill after run>` |
| Did latency alarm fire first? | `<fill after run>` |
| Detection latency (inject → first alarm) | `<fill after run>` |
| Alarms that fired | `<fill after run>` |
| Composite state change time | `<fill after run>` |
| SNS notification received? | `<fill after run>` |
| Dashboard evidence (screenshot / link) | `<fill after run>` |
| Notes | `<fill after run>` |

## Recover

Re-add the exact ingress rule (app SG → RDS 5432):

```bash
RDS_SG=$(aws ec2 describe-security-groups --region us-east-1 \
  --filters Name=group-name,Values=cops-rds-sg \
  --query "SecurityGroups[0].GroupId" --output text)
APP_SG=$(aws ec2 describe-security-groups --region us-east-1 \
  --filters Name=group-name,Values=cops-app-sg \
  --query "SecurityGroups[0].GroupId" --output text)

aws ec2 authorize-security-group-ingress --region us-east-1 \
  --group-id "$RDS_SG" \
  --protocol tcp --port 5432 --source-group "$APP_SG"
```

If the rule had extra attributes (description, etc.), restore from `/tmp/cops-rds-sg-ingress.json`. As a fallback, `terraform apply` will reconcile `cops-rds-sg` back to the declared state. Confirm: targets return healthy in `cops-app-tg`, `curl` returns 200, all alarms return to OK.

## Prevent / follow-up

- Add resilience: DB connection timeout + retry/backoff so a transient dependency blip doesn't instantly 5xx.
- Consider a lightweight `/health` that degrades gracefully (e.g., reports DB-down without hanging the request thread).
- Guard `cops-rds-sg` rules with drift detection / `terraform plan` in CI so accidental removal is caught.
- Confirm alarm ordering (unhealthy vs 5xx vs latency) matches expectations and that the on-call signal points at the DB dependency, not the app.

## RCA

After running, complete a write-up using [RCA-TEMPLATE.md](RCA-TEMPLATE.md).
