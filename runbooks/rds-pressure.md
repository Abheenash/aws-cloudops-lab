# Runbook: RDS Pressure

**Alarms:** `cops-rds-cpu` (CPUUtilization > 80% for 5 × 60s) and/or `cops-rds-connections` (DatabaseConnections > 80 for 3 × 60s) on `cops-db` · roll up into composite `cops-service-health`.

## When this fires
The Postgres instance `cops-db` is under load — high CPU and/or connection saturation. The app depends on `cops-db` **on every request**, so DB pressure surfaces to customers as **latency** (`cops-alb-latency-p95`) and **errors** (`cops-alb-5xx`) when the app can't get a connection. Common causes: connection leak / no pooling, a heavy or runaway query, or a real traffic spike.

## Validate
```bash
export AWS_REGION=us-east-1
ALB_DNS=$(aws elbv2 describe-load-balancers --names cops-alb --query 'LoadBalancers[0].DNSName' --output text)
```

Current DB state and metrics:
```bash
aws rds describe-db-instances --db-instance-identifier cops-db \
  --query 'DBInstances[0].{status:DBInstanceStatus,class:DBInstanceClass,maxconn:PendingModifiedValues}' --output table

for M in CPUUtilization DatabaseConnections FreeableMemory ReadLatency WriteLatency; do
  echo "== $M =="
  aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name $M \
    --dimensions Name=DBInstanceIdentifier,Value=cops-db \
    --start-time $(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ) --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
    --period 60 --statistics Average Maximum --output table
done
```

Customer impact (is the app degraded?):
```bash
for i in $(seq 1 10); do curl -s -o /dev/null -w "%{time_total}s  %{http_code}\n" http://$ALB_DNS/health; done
aws logs tail /cops/app --since 15m --filter-pattern '?connection ?timeout ?"too many" ?psycopg' --format short
```

Find what's consuming the DB (Postgres error/activity log):
```bash
aws logs tail /aws/rds/instance/cops-db/postgresql --since 30m --format short
```
Look for long-running or blocked queries and connection-limit messages. If you have a psql path via SSM/bastion, inspect `pg_stat_activity`:
```sql
SELECT pid, state, wait_event_type, now()-query_start AS runtime, left(query,120)
FROM pg_stat_activity WHERE state <> 'idle' ORDER BY runtime DESC LIMIT 20;
```

## Mitigate
1. **Runaway / long-running query** — terminate it (via psql):
   ```sql
   SELECT pg_terminate_backend(<pid>);
   ```
2. **Connection leak from the app** — recycle the app to drop stale connections (rolls the pool):
   ```bash
   INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names cops-app-asg \
     --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text)
   aws ssm send-command --instance-ids $INSTANCE_IDS --document-name AWS-RunShellScript \
     --parameters 'commands=["systemctl restart cops-app"]' --comment "recycle app to release DB connections"
   ```
3. **Legitimate load spike, CPU-bound** — the app tier scaling out will NOT help the DB; do not add app instances. Consider (with owner approval) scaling the DB vertically:
   ```bash
   aws rds modify-db-instance --db-instance-identifier cops-db \
     --db-instance-class db.t3.small --apply-immediately   # causes a brief failover/restart — confirm first
   ```
4. **Connection ceiling too low** — raise `max_connections` in the parameter group (requires reboot for static params) only if analysis shows headroom in memory.

## Roll back
- If you scaled the instance class and it caused problems (or was unnecessary), modify it back to the original class (`db.t3.micro`) — note this triggers another restart:
  ```bash
  aws rds modify-db-instance --db-instance-identifier cops-db --db-instance-class db.t3.micro --apply-immediately
  ```
- If a recent app deploy introduced the connection leak, redeploy the last-known-good version (`aws ssm list-commands --max-results 10 ...`) and restart `cops-app`.
- Revert any parameter-group change and reboot if it did not help.

## Verify recovery
```bash
aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=cops-db \
  --start-time $(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ) --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --statistics Average --output table     # back under 80%
aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value=cops-db \
  --start-time $(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ) --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --statistics Maximum --output table      # back under 80
for i in $(seq 1 10); do curl -s -o /dev/null -w "%{time_total}s  %{http_code}\n" http://$ALB_DNS/health; done  # fast 200s
aws cloudwatch describe-alarms --alarm-names cops-rds-cpu cops-rds-connections cops-service-health \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue}' --output table   # all OK
```
Also confirm the downstream `cops-alb-latency-p95` and `cops-alb-5xx` alarms return to OK.

## Escalate
- CPU or connections stay pinned > 15 min after mitigation, or the DB is at/near `max_connections` and the app can't connect (partial/full outage) — page DB owner immediately.
- Any action requiring an instance-class change, parameter-group reboot, or failover — get owner sign-off first (customer-visible restart).
- Signs of data-layer failure (replication, storage full, corruption) → DB owner + escalation.
