# Monthly Operating Report — July 2026

First operating report for the AWS Cloud Operations & Recovery Lab. Covers the
2026-07-10 drill session (build → operate → destroy). Numbers are measured.

## Service & availability

- **Environment:** EC2 Auto Scaling Group (2× t3.micro) + ALB + RDS Postgres 16, all Terraform.
- The lab runs **build → demo → destroy**, so there is no standing SLA; availability is assessed *during* the operated window. During the session the ALB served 200s except for the deliberately-induced outages below.

## Reliability — incident drills

Five fault-injection drills executed; full detail in [`../incidents/RESULTS-2026-07-10.md`](../incidents/RESULTS-2026-07-10.md).

| Drill | Detection | Result |
|---|---|---|
| Elevated 5xx | 177 s | alarm fired, recovered |
| Latency (p95) | 289 s | alarm fired, recovered |
| Instance failure | — | **self-healed before the alarm window** (finding) |
| RDS connection exhaustion | — | **threshold above instance ceiling** (finding) |
| DB dependency failure | 166 s | alarm fired, recovered |

**Alarm precision:** 3/5 drills paged correctly on the customer-facing symptom. The 2 that didn't fire surfaced real tuning gaps (see Action Items) — not silent failures, just alarms that need adjusting.

## Recovery — backup/restore test

- **RTO measured: 6 m 36 s** against a 60-minute target — **PASS**.
- Restore was **query-validated** (`SELECT version()` → PostgreSQL 16.13), not just "instance available."

## Change management — brownfield

- `terraform import` + drift detection + reconciliation demonstrated end-to-end on a real S3 resource ([`../brownfield/README.md`](../brownfield/README.md)).

## Cost

- **Standing cost of this lab: ~$0** — it's destroyed between sessions.
- **This session's run** (≈2 hrs of 2× t3.micro + ALB + RDS + a brief 2nd RDS for the restore) is a few dollars at most, prorated; see [`cost-model.md`](cost-model.md) for the monthly-if-left-running estimate. Account budget alarms ($1 zero-spend, $10 monthly) remain the backstop.

## Action items

| # | Item | Owner | Status |
|---|------|-------|--------|
| 1 | Tune `cops-unhealthy-targets` to catch single-instance failure (1×60 s, or alarm on `HealthyHostCount < desired`) | Abheenash | Open |
| 2 | Lower `cops-rds-connections` threshold to ~60–70% of the instance's real `max_connections`; evaluate RDS Proxy | Abheenash | Open |
| 3 | Give the app a bounded DB connection pool + fast-fail so DB pressure degrades gracefully | Abheenash | Open |
| 4 | Run the authored patch-compliance report against a live SSM Patch Manager baseline (not exercised this cycle) | Abheenash | Open |
| 5 | Enable the opt-in security baseline (GuardDuty/Config/Inspector/Security Hub) and triage first findings (account-wide; deliberately left off by default) | Abheenash | Open |

## Not run this cycle (deliberately)

- **Patch compliance & resource-health automation** — authored and syntax-verified (`automation/`), but not executed against live infra this session.
- **Security baseline** — authored as opt-in IaC (`terraform/security.tf`, default off) because it enables *account-wide* services; left off to avoid changing account-level posture during a throwaway lab. Enable deliberately when running the security-findings drill.
