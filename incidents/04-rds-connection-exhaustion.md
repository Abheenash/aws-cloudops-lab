# Drill 04 — RDS connection exhaustion

**Status:** ✅ EXECUTED 2026-07-10 — alarm **did not fire**: connections plateaued at 72, below the >80 threshold (above a t3.micro's real ceiling); pressure cascaded to app health; orphaned connections cleared by an RDS reboot. Findings: [RESULTS-2026-07-10.md](RESULTS-2026-07-10.md) · **Region:** us-east-1 · **Prefix:** cops

## Hypothesis

If a script opens many **idle** Postgres connections to `cops-db` and holds them open, then RDS `DatabaseConnections` will climb, alarm `cops-rds-connections` will trip (>80 connections for 3× 60s). As the connection count nears the instance limit, the app on `cops-app-asg` may fail to acquire a connection on its per-request DB call, producing HTTP 500s — so `cops-alb-5xx` (and the composite `cops-service-health`) may also fire. This drill tests both the DB-capacity alarm and the downstream user-facing effect.

## Blast radius & safety

- Lab-only DB; no production data.
- The load generator runs **on an app instance via SSM** (already in `cops-app-sg`, already allowed through `cops-rds-sg`), so no SG changes are needed.
- Fully reversible: killing the script closes its connections; `DatabaseConnections` drops back on its own. No schema or data writes — connections sit idle after a single `SELECT 1`.
- Safety cap: the helper opens a **bounded** number of connections (`--count`, default 120) and self-releases after `--hold` seconds (default 600) even if left unattended.
- Cost impact: negligible.

## Inject

Run the committed helper [`scripts/exhaust_connections.py`](scripts/exhaust_connections.py) on one app instance via SSM. It reads the DB credentials from the **RDS-managed Secrets Manager secret** (the same source the app uses) — no passwords on the command line. `psycopg2` and `boto3` are already installed by `user_data`.

```bash
# Resolve the DB endpoint + the RDS-managed secret ARN (run locally — needs rds:Describe)
DB_HOST=$(aws rds describe-db-instances --region us-east-1 \
  --db-instance-identifier cops-db \
  --query 'DBInstances[0].Endpoint.Address' --output text)
DB_SECRET_ARN=$(aws rds describe-db-instances --region us-east-1 \
  --db-instance-identifier cops-db \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)

# Pick one in-service instance
TARGET=$(aws autoscaling describe-auto-scaling-groups --region us-east-1 \
  --auto-scaling-group-names cops-app-asg \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId | [0]" \
  --output text)
echo "Running load from: $TARGET  (host=$DB_HOST)"

# Ship the helper to the instance (base64 = one safe line) and run it backgrounded
B64=$(base64 < scripts/exhaust_connections.py | tr -d '\n')
aws ssm send-command --region us-east-1 \
  --document-name "AWS-RunShellScript" \
  --targets "Key=InstanceIds,Values=$TARGET" \
  --comment "DRILL 04 open idle RDS connections" \
  --parameters "commands=[\"echo $B64 | base64 -d > /tmp/exhaust.py\",\"nohup python3 /tmp/exhaust.py --host $DB_HOST --secret-arn $DB_SECRET_ARN --dbname copsdb --count 120 --hold 600 --region us-east-1 > /tmp/exhaust.log 2>&1 &\",\"sleep 3; cat /tmp/exhaust.log\"]"
```

> The helper fetches credentials via the instance role's scoped `secretsmanager:GetSecretValue` on the RDS secret — so it only works from an app instance, which is correct.

Watch connections climb:

```bash
aws cloudwatch get-metric-statistics --region us-east-1 \
  --namespace AWS/RDS --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value=cops-db \
  --start-time "$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 --statistics Maximum --output table
```

## Expected detection (hypothesis — not a measured result)

- **`cops-rds-connections`** → ALARM. `DatabaseConnections` rises from baseline to >80 and holds; alarm trips after 3× 60s. Direction: **up**.
- **`cops-alb-5xx`** → possibly ALARM if the app can no longer acquire a DB connection per request and returns 500s. Record whether this happened — it's the key "did DB pressure become user-facing?" finding.
- **`cops-rds-cpu`** may rise but is not the primary target.
- **`cops-service-health`** (composite) → ALARM following any child.
- SNS `cops-alerts` delivers notifications.

## Observations — fill after execution

| Field | Value |
|-------|-------|
| Date/time injected (UTC) | `<fill after run>` |
| Peak `DatabaseConnections` | `<fill after run>` |
| Time `cops-rds-connections` entered ALARM | `<fill after run>` |
| Detection latency (inject → alarm) | `<fill after run>` |
| Did `cops-alb-5xx` also fire? (Y/N + time) | `<fill after run>` |
| Alarms that fired | `<fill after run>` |
| Composite state change time | `<fill after run>` |
| SNS notification received? | `<fill after run>` |
| Dashboard evidence (screenshot / link) | `<fill after run>` |
| Notes | `<fill after run>` |

## Recover

```bash
TARGET=$(aws autoscaling describe-auto-scaling-groups --region us-east-1 \
  --auto-scaling-group-names cops-app-asg \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId | [0]" \
  --output text)

# Kill the connection-holder; connections close and DatabaseConnections drops
aws ssm send-command --region us-east-1 \
  --document-name "AWS-RunShellScript" \
  --targets "Key=InstanceIds,Values=$TARGET" \
  --comment "DRILL 04 recover kill exhaust.py" \
  --parameters 'commands=["pkill -f /tmp/exhaust.py || true","rm -f /tmp/exhaust.py","echo killed"]'
```

The helper also self-releases after its `--hold` timeout as a backstop. Confirm: `DatabaseConnections` returns to baseline, `cops-rds-connections` returns to OK, app requests return 200, `cops-alb-5xx` (if it fired) returns to OK.

## Prevent / follow-up

- Right-size the app's DB connection pool + add connection timeouts/retries so a single client can't starve the app.
- Consider RDS Proxy or PgBouncer to multiplex connections and cap per-client usage.
- Confirm `cops-rds-connections` threshold (>80) leaves enough margin below the instance `max_connections` to alert *before* the app starts failing.
- Verify the app degrades gracefully (fast 503 / retry) rather than hanging when the DB is saturated.

## RCA

After running, complete a write-up using [RCA-TEMPLATE.md](RCA-TEMPLATE.md).
