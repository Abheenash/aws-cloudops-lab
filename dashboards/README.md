# Dashboards & alarms

The golden-signals dashboard and all alarms are defined as code in
[`terraform/observability.tf`](../terraform/observability.tf):

- Dashboard: **`cops-golden-signals`** — traffic, target 5xx, latency p50/p95,
  healthy/unhealthy targets, RDS CPU, RDS connections.
- Alarms (all `cops-*` → SNS `cops-alerts`): `cops-alb-5xx`,
  `cops-alb-latency-p95`, `cops-unhealthy-targets`, `cops-rds-cpu`,
  `cops-rds-connections`, and the composite `cops-service-health`.

Export the live dashboard JSON as evidence:

```bash
aws cloudwatch get-dashboard \
  --dashboard-name cops-golden-signals \
  --query DashboardBody --output text > cops-golden-signals.json
```

(Or, in the console: open the dashboard → **Actions → View/edit source** → copy
the JSON.)

> Add exported JSON and annotated screenshots here as drills are completed.
> See the [roadmap](../README.md#roadmap).
