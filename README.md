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

- **Compute:** a small Flask service on an EC2 Auto Scaling Group behind an Application Load Balancer (EC2 on purpose — so patching, Linux troubleshooting, and instance-recovery drills are real; see [ADR-001](architecture/adr-001-ec2-over-ecs.md)).
- **Data:** Amazon RDS (with automated backups + a tested restore path).
- **Observability:** CloudWatch dashboards (golden signals), Logs Insights queries, actionable alarms, a synthetics canary.
- **Operations:** SSM Patch Manager (patch compliance), AWS Backup, resource scheduling for non-prod.
- **Governance/security:** AWS Config, GuardDuty, Inspector, Security Hub; findings triaged and remediated.
- **Cost:** budgets + a monthly operating/cost report.
- **IaC:** Terraform — including a deliberate **import/drift exercise** on a manually-created resource to practice brownfield reconciliation.

Full diagram lands in [`architecture/`](architecture/).

## Roadmap

**Authored & validated** (the code, plans, and procedures are in this repo):

- [x] Base workload as Terraform — EC2 ASG (Flask app) + ALB + RDS Postgres (`terraform/`, `terraform validate` clean)
- [x] Observability: golden-signals dashboard, five alarms + composite health, saved Logs Insights queries, SNS (`terraform/observability.tf`)
- [x] Runbooks — one per actionable alarm (`runbooks/`)
- [x] Five incident **drill plans** with exact injection/recovery commands (`incidents/`)
- [x] Patch-compliance, resource-health, and non-prod-scheduler automation (`automation/`)
- [x] Timed restore-test plan against a 60-min RTO (`restore-tests/`)
- [x] Security baseline as IaC (GuardDuty/Security Hub/Inspector/Config), opt-in (`terraform/security.tf`)
- [x] Cost model + monthly operating-report template + budget guardrail (`cost-analysis/`, `terraform/budgets.tf`)
- [x] Architecture diagram + ADRs (`architecture/`)

**Execution** (populates the evidence folders with real, measured results — run against a live `terraform apply`):

- [x] **All 5 incident drills executed (2026-07-10)** — full report: [incidents/RESULTS-2026-07-10.md](incidents/RESULTS-2026-07-10.md). 3 alarms fired (177 s / 289 s / 166 s); 2 surfaced real alarm-tuning findings (single-instance failure self-heals before the alarm; rds-connections threshold above the instance ceiling). Drill 01 also has a standalone [RCA](incidents/2026-07-10-drill01-rca.md).
- [x] **Timed restore test** — measured **RTO 6 m 36 s** vs the 60-min target, query-validated ([RESULTS](incidents/RESULTS-2026-07-10.md#restore-test--pass)).
- [x] **Brownfield import/drift** — `terraform import` → drift → detect → revert, captured in [brownfield/README.md](brownfield/README.md).
- [x] **Monthly operating report** from real numbers — [cost-analysis/2026-07-operating-report.md](cost-analysis/2026-07-operating-report.md).
- [ ] Enable the opt-in security baseline; triage first GuardDuty/Config/Inspector findings (account-wide services, deliberately left off by default — see the operating report).

> **Honesty note:** every "Observations / Results" table in this repo is intentionally left with `<fill after run>` cells. Measured numbers get written only after the drill is actually executed — not before.

## Repo map

| Folder | What lives here |
| --- | --- |
| [`architecture/`](architecture/) | Diagrams and an architecture decision record (ADR) |
| [`terraform/`](terraform/) | IaC for the workload + the import/drift exercise |
| [`automation/`](automation/) | Python/Boto3 · Lambda · EventBridge · SSM automation |
| [`dashboards/`](dashboards/) | CloudWatch dashboard + alarm definitions |
| [`logs-insights/`](logs-insights/) | Saved, sanitized Logs Insights queries |
| [`runbooks/`](runbooks/) | One runbook per actionable alarm (validate → mitigate → roll back → verify) |
| [`incidents/`](incidents/) | Five incident drill plans + RCA template (results fill on execution) |
| [`restore-tests/`](restore-tests/) | Backup/restore test plans and timed results |
| [`cost-analysis/`](cost-analysis/) | Baseline vs revised cost, scheduling savings, monthly report |
| [`security-findings/`](security-findings/) | Findings from Config/GuardDuty/Inspector + remediation notes |

## Cost discipline

This lab is built to run cheaply and be torn down between sessions (`terraform destroy`). Cost decisions and the monthly spend model are documented in [`cost-analysis/`](cost-analysis/) — reliability-vs-cost trade-offs are part of the story, not an afterthought.

---

*Part of a three-then-four project cloud portfolio — build → ship → operate → **recover**. More at [abheenash.com](https://abheenash.com).*
