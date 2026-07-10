# Terraform — Cloud Ops Lab infrastructure

The whole lab as code: VPC, ALB, an EC2 Auto Scaling Group running a small Flask
app, RDS Postgres, the golden-signals dashboard + alarms + SNS, an (opt-in)
account-wide security baseline, and a monthly budget guardrail.

## What it builds

| File | Resources |
| --- | --- |
| `network.tf` / `security_groups.tf` | VPC, 2 public + 2 private subnets, IGW, route tables, SGs |
| `alb.tf` | Application Load Balancer, target group (`/health`), HTTP listener |
| `ec2.tf` / `user_data.sh.tftpl` | Launch template + ASG; user-data installs the Flask app + CloudWatch agent |
| `rds.tf` | RDS Postgres, private subnets, RDS-managed master secret |
| `iam.tf` | EC2 instance role (SSM + CloudWatch + read the DB secret only) |
| `observability.tf` | Log group, SNS, 5 alarms, composite `cops-service-health`, dashboard, saved queries |
| `security.tf` | GuardDuty, Security Hub, Inspector, AWS Config — **gated behind `enable_security_baseline` (default off)** |
| `budgets.tf` | Monthly cost budget with 80% actual / 100% forecast alerts |

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # edit alarm_email etc.
terraform init
terraform apply
```

`terraform output app_url` gives the ALB URL. Give the app a couple of minutes
after apply — the instances install Python/Flask on first boot.

## Drill toggles

The app reads two flag files so incident drills can inject failure safely
(see [`../incidents/`](../incidents/)):

- `/opt/app/FORCE_500` → the app returns HTTP 500
- `/opt/app/FORCE_SLOW` → the app adds 5s latency

Set/clear them over SSM (no SSH), e.g.:

```bash
aws ssm send-command --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Patch Group,Values=cops-app" \
  --parameters 'commands=["touch /opt/app/FORCE_500"]'
```

## Cost & teardown

This lab bills while it runs (ALB + RDS are the drivers). It's designed to be
stood up for a session and torn down:

```bash
terraform destroy
```

See [`../cost-analysis/`](../cost-analysis/) for the estimated monthly model.

## Notes

- **No SSH** — instances are reached via SSM Session Manager / Run Command only.
- **No hardcoded secrets** — RDS generates and rotates its master password in
  Secrets Manager; the app reads it at runtime; the instance role can read only
  that one secret.
- `enable_security_baseline = true` turns on the account-wide security services
  for the security-findings drill — they bill separately, so it's off by default.
