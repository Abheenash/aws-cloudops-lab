# Runbook: High Latency (p95)

**Alarm:** `cops-alb-latency-p95` (target response p95 > 1.5s for 3 × 60s) · rolls up into composite `cops-service-health`.

## When this fires
The app behind `cops-alb` (target group `cops-app-tg`) is slow: 95% of requests are taking longer than 1.5s. Customers experience sluggish responses and timeouts. Common causes: the `FORCE_SLOW` failure toggle (+5s), slow/contended RDS `cops-db` queries, CPU saturation on the t3.micro instances, or one degraded instance dragging the percentile.

## Validate
```bash
export AWS_REGION=us-east-1
ALB_DNS=$(aws elbv2 describe-load-balancers --names cops-alb --query 'LoadBalancers[0].DNSName' --output text)
ALB_DIM=$(aws elbv2 describe-load-balancers --names cops-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text | cut -d: -f6 | cut -d/ -f2-)
TG_ARN=$(aws elbv2 describe-target-groups --names cops-app-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names cops-app-asg \
  --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text)
```

Feel the latency yourself:
```bash
for i in $(seq 1 10); do curl -s -o /dev/null -w "%{time_total}s  %{http_code}\n" http://$ALB_DNS/health; done
```

Confirm the p95 metric:
```bash
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB \
  --metric-name TargetResponseTime --dimensions Name=LoadBalancer,Value=$ALB_DIM \
  --start-time $(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ) --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --extended-statistics p95 --output table
```

Check for the `FORCE_SLOW` toggle on each instance:
```bash
aws ssm send-command --instance-ids $INSTANCE_IDS --document-name AWS-RunShellScript \
  --parameters 'commands=["ls -la /opt/app/FORCE_SLOW 2>&1 || echo NO_TOGGLE"]' \
  --comment "check FORCE_SLOW" --query 'Command.CommandId' --output text
# then: aws ssm list-command-invocations --command-id <id> --details --query 'CommandInvocations[].CommandPlugins[].Output' --output text
```

Rule out RDS and CPU:
```bash
aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=cops-db \
  --start-time $(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ) --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --statistics Average --output table
aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization \
  --dimensions Name=AutoScalingGroupName,Value=cops-app-asg \
  --start-time $(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ) --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --statistics Average --output table
aws logs tail /cops/app --since 15m --filter-pattern '?slow ?timeout ?latency' --format short
```
If RDS CPU/connections are high, switch to **rds-pressure.md**.

## Mitigate
1. **If `FORCE_SLOW` is present**, remove it on every instance:
   ```bash
   aws ssm send-command --instance-ids $INSTANCE_IDS --document-name AWS-RunShellScript \
     --parameters 'commands=["rm -f /opt/app/FORCE_SLOW","systemctl restart cops-app || true"]' \
     --comment "clear FORCE_SLOW"
   ```
2. **If one instance is the slow one** (per-target latency), mark it unhealthy to shed its traffic and let the ASG replace it:
   ```bash
   aws autoscaling set-instance-health --instance-id <slow-id> --health-status Unhealthy --no-should-respect-grace-period
   ```
3. **If CPU-bound across the fleet**, scale out temporarily:
   ```bash
   aws autoscaling set-desired-capacity --auto-scaling-group-name cops-app-asg --desired-capacity 3 --honor-cooldown
   ```
4. **If RDS is the bottleneck**, follow **rds-pressure.md**.

## Roll back
If a deploy or config push preceded the alarm:
```bash
aws ssm list-commands --max-results 10 \
  --query 'Commands[].{id:CommandId,doc:DocumentName,time:RequestedDateTime,comment:Comment}' --output table
```
Redeploy the last-known-good app version and `systemctl restart cops-app`. If you scaled out in step 3, return desired capacity to 2 once p95 recovers:
```bash
aws autoscaling set-desired-capacity --auto-scaling-group-name cops-app-asg --desired-capacity 2
```

## Verify recovery
```bash
for i in $(seq 1 20); do curl -s -o /dev/null -w "%{time_total}s  %{http_code}\n" http://$ALB_DNS/health; done  # < ~0.5s, 200s
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB --metric-name TargetResponseTime \
  --dimensions Name=LoadBalancer,Value=$ALB_DIM \
  --start-time $(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ) --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --extended-statistics p95 --output table                                              # p95 < 1.5s
aws cloudwatch describe-alarms --alarm-names cops-alb-latency-p95 cops-service-health \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue}' --output table                         # both OK
```
p95 must stay under 1.5s for 3 consecutive periods for the alarm to clear.

## Escalate
- p95 stays > 1.5s for > 20 min after mitigation with no identified cause.
- Root cause is RDS saturation you can't relieve → DB owner (rds-pressure.md).
- Scaling out does not help and CPU stays pinned (may need larger instance type — capacity/infra owner).
