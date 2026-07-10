# Runbook: Instance Failure

**Alarms:** typically `cops-unhealthy-targets` (UnHealthyHostCount ≥ 1) and/or `cops-alb-5xx` / `cops-alb-latency-p95`, plus a drop in ASG healthy count · roll up into composite `cops-service-health`.

## When this fires
One (or both) of the t3.micro instances in `cops-app-asg` has failed or become unreachable — EC2 status-check failure, kernel hang, out-of-memory, disk full, SSM agent offline, or the instance was terminated. The ALB pulls it from rotation, so capacity drops; with only 2 instances, losing one halves capacity and losing both is a full outage (ALB 503).

## Validate
```bash
export AWS_REGION=us-east-1
TG_ARN=$(aws elbv2 describe-target-groups --names cops-app-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --names cops-alb --query 'LoadBalancers[0].DNSName' --output text)
```

ASG membership and lifecycle:
```bash
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names cops-app-asg \
  --query 'AutoScalingGroups[0].{desired:DesiredCapacity,min:MinSize,max:MaxSize,instances:Instances[].{id:InstanceId,life:LifecycleState,health:HealthStatus,az:AvailabilityZone}}' \
  --output json
aws autoscaling describe-scaling-activities --auto-scaling-group-name cops-app-asg --max-items 5 \
  --query 'Activities[].{time:StartTime,status:StatusCode,desc:Description,cause:Cause}' --output table
```

EC2 status checks (system vs instance):
```bash
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names cops-app-asg \
  --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text)
aws ec2 describe-instance-status --instance-ids $INSTANCE_IDS --include-all-instances \
  --query 'InstanceStatuses[].{id:InstanceId,state:InstanceState.Name,sys:SystemStatus.Status,inst:InstanceStatus.Status}' --output table
```

Is the instance reachable via SSM at all?
```bash
aws ssm describe-instance-information \
  --query 'InstanceInformationList[].{id:InstanceId,ping:PingStatus,agent:AgentVersion,lastping:LastPingDateTime}' --output table
```
`PingStatus: ConnectionLost` = SSM agent/instance is down. Customer impact:
```bash
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'length(TargetHealthDescriptions[?TargetHealthState.State==`healthy`])'
curl -s -o /dev/null -w "%{http_code}\n" http://$ALB_DNS/health   # 503 = zero healthy hosts
```

If SSM is still up, check the box for OOM / disk-full:
```bash
BAD_ID=<instance-id>
CID=$(aws ssm send-command --instance-ids $BAD_ID --document-name AWS-RunShellScript \
  --parameters 'commands=["uptime","df -h /","free -m","journalctl -k --no-pager | tail -20","systemctl is-active cops-app amazon-ssm-agent"]' \
  --query 'Command.CommandId' --output text)
sleep 5
aws ssm list-command-invocations --command-id $CID --details --query 'CommandInvocations[].CommandPlugins[].Output' --output text
```

## Mitigate
1. **Fastest safe recovery — replace the instance.** Mark it unhealthy so the ASG terminates and launches a fresh one from the launch template:
   ```bash
   aws autoscaling set-instance-health --instance-id $BAD_ID --health-status Unhealthy --no-should-respect-grace-period
   ```
2. **Confirm/restore desired capacity** so a replacement is actually launched (and to cover a lost instance):
   ```bash
   aws autoscaling set-desired-capacity --auto-scaling-group-name cops-app-asg --desired-capacity 2 --honor-cooldown
   ```
   If you need extra headroom while replacements warm up, temporarily bump to 3.
3. **Reachable but soft-failed** (app dead, disk recoverable) and you want to avoid a rebuild — try in-place recovery via SSM, else fall back to replacement:
   ```bash
   aws ssm send-command --instance-ids $BAD_ID --document-name AWS-RunShellScript \
     --parameters 'commands=["systemctl restart amazon-ssm-agent","systemctl restart cops-app","df -h /"]' \
     --comment "in-place recovery attempt"
   ```
4. **Both instances down (full outage)** — do steps 1–2 immediately for the whole ASG, and escalate in parallel.

## Roll back
- If replacement instances launch but come up broken, the launch template / AMI / user_data is suspect. Point the ASG back at the last-known-good launch template version and refresh:
  ```bash
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names cops-app-asg \
    --query 'AutoScalingGroups[0].LaunchTemplate' --output json
  # set the known-good version, then:
  aws autoscaling start-instance-refresh --auto-scaling-group-name cops-app-asg
  ```
- If a recent Terraform apply or config push changed the launch template, revert that change (do not `terraform apply` speculatively during an incident unless it is the confirmed fix).

## Verify recovery
```bash
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names cops-app-asg \
  --query 'AutoScalingGroups[0].Instances[].{id:InstanceId,life:LifecycleState,health:HealthStatus}' --output table  # 2× InService/Healthy
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].{id:Target.Id,state:TargetHealthState.State}' --output table                   # all healthy
for i in $(seq 1 10); do curl -s -o /dev/null -w "%{http_code}\n" http://$ALB_DNS/health; done                       # 200s
aws cloudwatch describe-alarms --alarm-names cops-unhealthy-targets cops-alb-5xx cops-alb-latency-p95 cops-service-health \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue}' --output table                                          # all OK
```
Confirm the replacement instance registers in SSM (`aws ssm describe-instance-information`) so future runbooks can reach it.

## Escalate
- Both instances down / ALB serving 503 — full outage, page next tier immediately (do not wait for auto-replacement).
- ASG cannot launch replacements (capacity/quota error, subnet/AZ issue, bad launch template) → infra owner.
- Repeated failures of fresh instances (crash loop, OOM on every launch) — likely a bad AMI/user_data or undersized instance; escalate to service + infra owners.
- Suspected AWS platform issue (multiple system-status-check failures across AZ) — check AWS Health Dashboard and escalate.
