# Runbook: Elevated 5xx

**Alarm:** `cops-alb-5xx` (Target 5xx Sum ≥ 3 over 60s) · rolls up into composite `cops-service-health`.

## When this fires
The ALB `cops-alb` is receiving HTTP 500-class responses **from the app targets** (target group `cops-app-tg`, port 8080), not from the ALB itself. Customers are seeing failed requests / error pages. Most likely causes: an app fault on one or more instances (including the `FORCE_500` failure toggle), a bad deploy, or the app failing because RDS `cops-db` is unreachable.

## Validate
Set shared vars first:
```bash
export AWS_REGION=us-east-1
ALB_ARN=$(aws elbv2 describe-load-balancers --names cops-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --names cops-app-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --names cops-alb --query 'LoadBalancers[0].DNSName' --output text)
ALB_DIM=$(aws elbv2 describe-load-balancers --names cops-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text | cut -d: -f6 | cut -d/ -f2-)
```

Confirm customer impact — hit the app directly a few times:
```bash
for i in $(seq 1 10); do curl -s -o /dev/null -w "%{http_code}\n" http://$ALB_DNS/health; done
```

Quantify the 5xx rate (last 15 min):
```bash
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB \
  --metric-name HTTPCode_Target_5XX_Count --dimensions Name=LoadBalancer,Value=$ALB_DIM \
  --start-time $(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ) --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --statistics Sum --output table
```

Is it all targets or one? Check target health:
```bash
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].{id:Target.Id,state:TargetHealthState.State,reason:TargetHealthState.Reason}' --output table
```

Look at the app errors and check for the failure toggle:
```bash
aws logs tail /cops/app --since 15m --filter-pattern '"500"' --format short
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names cops-app-asg \
  --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text)
for id in $INSTANCE_IDS; do
  echo "== $id =="
  aws ssm send-command --instance-ids $id --document-name AWS-RunShellScript \
    --parameters 'commands=["ls -la /opt/app/FORCE_500 2>&1 || echo NO_TOGGLE"]' \
    --query 'Command.CommandId' --output text
done
```
(Retrieve output: `aws ssm list-command-invocations --command-id <id> --details --query 'CommandInvocations[].CommandPlugins[].Output' --output text`)

Rule out RDS as the root cause (if DB is down the app 500s):
```bash
aws logs tail /cops/app --since 15m --filter-pattern '?psycopg ?connection ?database' --format short
aws rds describe-db-instances --db-instance-identifier cops-db --query 'DBInstances[0].DBInstanceStatus' --output text
```
If RDS is the cause, switch to **rds-pressure.md**.

## Mitigate
1. **If the `FORCE_500` toggle is present** (drill or accidental), remove it on every instance:
   ```bash
   aws ssm send-command --instance-ids $INSTANCE_IDS --document-name AWS-RunShellScript \
     --parameters 'commands=["rm -f /opt/app/FORCE_500","systemctl restart cops-app || true"]' \
     --comment "clear FORCE_500"
   ```
2. **If one instance is bad and the rest are healthy**, mark it unhealthy so the ASG replaces it and it stops taking traffic:
   ```bash
   BAD_ID=<instance-id>
   aws autoscaling set-instance-health --instance-id $BAD_ID --health-status Unhealthy --no-should-respect-grace-period
   ```
3. **If a recent deploy is the cause**, roll it back (see below).
4. **If RDS is the cause**, follow **rds-pressure.md** — do not restart the app repeatedly.
5. **If app is wedged app-wide but code is fine**, restart the service on all instances:
   ```bash
   aws ssm send-command --instance-ids $INSTANCE_IDS --document-name AWS-RunShellScript \
     --parameters 'commands=["systemctl restart cops-app"]' --comment "restart app on 5xx"
   ```

## Roll back
If a change (deploy/config push via SSM) preceded the alarm:
```bash
# Identify recent Run Commands that touched the fleet
aws ssm list-commands --max-results 10 \
  --query 'Commands[].{id:CommandId,doc:DocumentName,time:RequestedDateTime,comment:Comment}' --output table
```
Redeploy the last-known-good app version (re-run your deploy Run Command / user_data pointing at the previous artifact), then restart `cops-app`. If the config change was a toggle or env file, restore it and `systemctl restart cops-app`.

## Verify recovery
```bash
for i in $(seq 1 20); do curl -s -o /dev/null -w "%{http_code}\n" http://$ALB_DNS/health; done   # expect 200s
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].TargetHealthState.State' --output text                       # all "healthy"
aws cloudwatch describe-alarms --alarm-names cops-alb-5xx cops-service-health \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue}' --output table                        # both OK
```
5xx count should return to 0 for two consecutive 60s periods and the alarm transitions to OK.

## Escalate
Page the service owner / next tier if any of:
- 5xx persists > 15 min after mitigation, or affects **all** targets with no clear cause.
- Root cause is RDS and `cops-db` is unavailable — escalate to DB owner (see rds-pressure.md).
- A rollback is required but the last-known-good artifact/version is unknown.
- Fleet is 0 healthy targets → also engage **unhealthy-targets.md** / **instance-failure.md**.
