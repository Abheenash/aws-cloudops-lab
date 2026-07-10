# Logs Insights queries

The saved CloudWatch Logs Insights queries are defined as code in
[`terraform/observability.tf`](../terraform/observability.tf) (as
`aws_cloudwatch_query_definition` resources):

- **`cops/app-5xx-responses`** — app log lines mentioning 500 / 503, over `/cops/app`.
- **`cops/app-error-log`** — error log streams over `/cops/app`.
- **`cops/rds-postgres-log`** — ERROR / FATAL / "too many" lines over the
  `cops-db` PostgreSQL log group.

Open them in the console under **CloudWatch → Logs Insights → Queries** (saved
queries), or list them with:

```bash
aws logs describe-query-definitions --query-definition-name-prefix cops/
```

> Add query results and triage notes here as drills are completed.
> See the [roadmap](../README.md#roadmap).
