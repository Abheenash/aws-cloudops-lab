# AWS Cloud Operations & Recovery Lab

> 🚧 **Status: active / in progress.** This is a deliberately-*operated* AWS environment — not another greenfield build. The point isn't to stand up services; it's to run them, break them on purpose, detect the failure, recover it, and record the evidence. Folders below are populated as each drill is completed.

## Why this project exists

My other three AWS projects ([serverless-file-share](https://github.com/Abheenash/serverless-file-share), [secure-container-pipeline](https://github.com/Abheenash/secure-container-pipeline), [cloud-observability-sre](https://github.com/Abheenash/cloud-observability-sre)) show that I can **build** and **ship** secure architecture. What a build repo can't show is the day-2 story: inheriting infrastructure, taking a page at 2am, running a restore test against an RTO, chasing drift, and writing the RCA afterward.

This lab exists to demonstrate that operational muscle on a small, real system — the same loop a CloudOps/DevOps engineer runs every week.

## The operating loop

```
provision  →  break  →  detect  →  recover  →  document  →  prevent recurrence
```

Every incident in this repo is run through that full loop, and the artifacts (alarm that fired, diagnostic evidence, recovery action, RCA, corrective change) are committed as proof — not screenshots of a green dashboard.

## Target architecture

A modest but production-shaped workload:

- **Compute:** a small containerized service on ECS (or EC2) behind an Application Load Balancer.
- **Data:** Amazon RDS (with automated backups + a tested restore path).
- **Observability:** CloudWatch dashboards (golden signals), Logs Insights queries, actionable alarms, a synthetics canary.
- **Operations:** SSM Patch Manager (patch compliance), AWS Backup, resource scheduling for non-prod.
- **Governance/security:** AWS Config, GuardDuty, Inspector, Security Hub; findings triaged and remediated.
- **Cost:** budgets + a monthly operating/cost report.
- **IaC:** Terraform — including a deliberate **import/drift exercise** on a manually-created resource to practice brownfield reconciliation.

Full diagram lands in [`architecture/`](architecture/).

## Roadmap

- [ ] Provision the base workload (ECS/EC2 + ALB + RDS) in Terraform
- [ ] Wire observability: dashboard, Logs Insights queries, alarms, canary
- [ ] Brownfield exercise: create a resource by hand, then `terraform import` + resolve drift
- [ ] Patch compliance via SSM Patch Manager + compliance report
- [ ] AWS Backup + a **timed restore test** against a defined RTO
- [ ] Security baseline: Config + GuardDuty + Inspector + Security Hub, triage findings
- [ ] Cost: budgets + non-prod scheduling + monthly cost report
- [ ] **Five incident drills**, each with detection time, evidence, recovery, and RCA
- [ ] Monthly operating report tying it all together

## Repo map

| Folder | What lives here |
| --- | --- |
| [`architecture/`](architecture/) | Diagrams and an architecture decision record (ADR) |
| [`terraform/`](terraform/) | IaC for the workload + the import/drift exercise |
| [`automation/`](automation/) | Python/Boto3 · Lambda · EventBridge · SSM automation |
| [`dashboards/`](dashboards/) | CloudWatch dashboard + alarm definitions |
| [`logs-insights/`](logs-insights/) | Saved, sanitized Logs Insights queries |
| [`runbooks/`](runbooks/) | One runbook per actionable alarm (validate → mitigate → roll back → verify) |
| [`incidents/`](incidents/) | Sanitized incident timelines + root-cause analyses |
| [`restore-tests/`](restore-tests/) | Backup/restore test plans and timed results |
| [`cost-analysis/`](cost-analysis/) | Baseline vs revised cost, scheduling savings, monthly report |
| [`security-findings/`](security-findings/) | Findings from Config/GuardDuty/Inspector + remediation notes |

## Cost discipline

This lab is built to run cheaply and be torn down between sessions (`terraform destroy`). Cost decisions and the monthly spend model are documented in [`cost-analysis/`](cost-analysis/) — reliability-vs-cost trade-offs are part of the story, not an afterthought.

---

*Part of a three-then-four project cloud portfolio — build → ship → operate → **recover**. More at [abheenash.com](https://abheenash.com).*
