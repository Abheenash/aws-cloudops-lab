# Incident drills & RCAs

Game-day chaos drills for the AWS Cloud Ops Lab. Each drill is a **plan written before execution**: it states a hypothesis, injects a controlled, reversible failure using the real resource names, and records which alarm should trip. Evidence (detection times, screenshots, notes) is filled in *after* the drill runs — cells left as `<fill after run>` have not been executed yet.

> Honesty rule: nothing in the "Observations" tables is real until a drill has actually been run. "Expected detection" is a labeled hypothesis, not a result.

## Environment under test

- Region: `us-east-1` · resource prefix: `cops`
- Flask app on ASG `cops-app-asg` (2× t3.micro, SSM-managed, no SSH) behind ALB `cops-alb` (`:80` → TG `cops-app-tg` `:8080`, health `/health`); app hits RDS Postgres `cops-db` on every request.
- Failure toggles (via SSM Run Command): `/opt/app/FORCE_500` → HTTP 500; `/opt/app/FORCE_SLOW` → +5s latency. Remove the file to recover.
- Alarms notify SNS `cops-alerts`; composite alarm `cops-service-health` rolls them up.

## Drill → alarm index

| # | Drill | Injection | Expected alarm(s) to trip | Self-heals? |
|---|-------|-----------|---------------------------|-------------|
| [01](01-elevated-5xx.md) | Elevated 5xx | `FORCE_500` on both instances via SSM | `cops-alb-5xx` → `cops-service-health` | No — manual recover |
| [02](02-latency.md) | Latency degradation | `FORCE_SLOW` on both instances via SSM | `cops-alb-latency-p95` → `cops-service-health` | No — manual recover |
| [03](03-instance-failure.md) | Instance failure | Terminate one ASG instance (no decrement) | `cops-unhealthy-targets` (transient) | Yes — ASG replaces it |
| [04](04-rds-connection-exhaustion.md) | RDS connection exhaustion | SSM script opens many idle Postgres connections to `cops-db` | `cops-rds-connections` (possibly `cops-alb-5xx`) → `cops-service-health` | Partial — kill script + connections drop |
| [05](05-db-dependency-failure.md) | DB dependency failure | Remove app-ingress rule on `cops-rds-sg` | `cops-unhealthy-targets` / `cops-alb-5xx` → `cops-service-health` | No — restore SG rule |

## After every drill

Write up the outcome using [RCA-TEMPLATE.md](RCA-TEMPLATE.md): summary, timeline, impact, root cause, contributing factors, what went well, and corrective actions with owners.
