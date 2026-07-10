# Runbook: Unhealthy Targets

**Alarm:** `cops-unhealthy-targets` (UnHealthyHostCount ≥ 1 for 2 × 60s) · rolls up into composite `cops-service-health`.

## When this fires
At least one target in `cops-app-tg` is failing the ALB health check (`GET /health` on :8080). Capacity is reduced; if both t3.micro instances go unhealthy the service is fully down (0 healthy hosts → ALB returns 503). Common causes: app crashed / not listening on 8080, instance still booting, `FORCE_500` making `/health` fail, or the instance itself is impaired.

## Validate
```bash
export AWS_REGION=us-east-1
TG_ARN=$(aws elbv2 describe-target-groups --names cops-app-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --names cops-alb --query 'LoadBalancers[0].DNSName' --output text)
```

See which targets are unhealthy and why:
```bash
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].{id:Target.Id,port:Target.Port,state:TargetHealthState.State,reason:TargetHealthState.Reason,desc:TargetHealthState.Description}' \
  --output table
```
`Target.ResponseCodeMismatch` / `Target.Timeout` → app problem. `Target.FailedHealthChecks` right after launch → probably still warming up.

Customer impact — how many healthy hosts remain:
```bash
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'length(TargetHealthDescriptions[?TargetHealthState.State==`healthy`])'
curl -s -o /dev/null -w "%{http_code}\n" http://$ALB_DNS/health   # 503 = no healthy hosts
```

On an unhealthy instance, confirm the app is listening and check the toggle:
```bash
BAD_ID=<unhealthy-instance-id>
CID=$(aws ssm send-command --instance-ids $BAD_ID --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl status cops-app --no-pager | head -20","ss -ltnp | grep :8080 || echo NOT_LISTENING","curl -s -o /dev/null -w \"local_health=%{http_code}\\n\" http://localhost:8080/health","ls -la /opt/app/FORCE_500 2>&1 || echo NO_TOGGLE"]' \
  --query 'Command.CommandId' --output text)
sleep 5
aws ssm list-command-invocations --command-id $CID --details \
  --query 'CommandInvocations[].CommandPlugins[].Output' --output text
aws logs tail /cops/app --since 15m --format short
```

## Mitigate
1. **App down but instance healthy** — restart the service:
   ```bash
   aws ssm send-command --instance-ids $BAD_ID --document-name AWS-RunShellScript \
     --parameters 'commands=["systemctl restart cops-app","sleep 3","curl -s -o /dev/null -w \"%{http_code}\\n\" http://localhost:8080/health"]' \
     --comment "restart cops-app on unhealthy target"
   ```
2. **`FORCE_500` present** (health check fails on purpose) — clear it:
   ```bash
   aws ssm send-command --instance-ids $BAD_ID --document-name AWS-RunShellScript \
     --parameters 'commands=["rm -f /opt/app/FORCE_500","systemctl restart cops-app"]' --comment "clear FORCE_500"
   ```
3. **Instance impaired / won't recover** — mark unhealthy so the ASG terminates and replaces it:
   ```bash
   aws autoscaling set-instance-health --instance-id $BAD_ID --health-status Unhealthy --no-should-respect-grace-period
   aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names cops-app-asg \
     --query 'AutoScalingGroups[0].Instances[].{id:InstanceId,life:LifecycleState,health:HealthStatus}' --output table
   ```
   If capacity dropped, restore desired count so a replacement launches:
   ```bash
   aws autoscaling set-desired-capacity --auto-scaling-group-name cops-app-asg --desired-capacity 2 --honor-cooldown
   ```
4. **App failing because RDS is down** — see **rds-pressure.md**; restarting the app won't help.

## Roll back
If a deploy/config push caused targets to start failing `/health`:
```bash
aws ssm list-commands --max-results 10 \
  --query 'Commands[].{id:CommandId,doc:DocumentName,time:RequestedDateTime,comment:Comment}' --output table
```
Redeploy the last-known-good app version and `systemctl restart cops-app`. If a full instance replacement is under way, let the ASG launch fresh instances from the known-good launch template rather than patching in place.

## Verify recovery
```bash
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].{id:Target.Id,state:TargetHealthState.State}' --output table  # all "healthy"
for i in $(seq 1 10); do curl -s -o /dev/null -w "%{http_code}\n" http://$ALB_DNS/health; done       # 200s
aws cloudwatch describe-alarms --alarm-names cops-unhealthy-targets cops-service-health \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue}' --output table                          # both OK
```
UnHealthyHostCount must read 0 for 2 consecutive periods to clear.

## Escalate
- Both instances unhealthy (0 healthy hosts / ALB serving 503) and not recovering within a few minutes — full outage, page next tier immediately.
- ASG launches replacement instances that also come up unhealthy (bad AMI / launch template / user_data) → infra owner.
- Health failures trace to RDS → DB owner (rds-pressure.md).
