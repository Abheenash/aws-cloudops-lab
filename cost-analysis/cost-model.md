# Cost Model — AWS Cloud Ops Lab (ESTIMATE)

> **This is an ESTIMATE, not a bill.** All figures below are rounded public
> on-demand list prices for **us-east-1**, used to reason about relative cost and
> right-sizing. They are **not** actual billed amounts. Real spend depends on hours
> run, data volume, free-tier eligibility, and taxes. For real numbers, see AWS Cost
> Explorer / the monthly bill and the AWS Pricing Calculator. Prices drift over time —
> re-check before quoting.

- **Scope:** the shared lab stack — RDS `cops-db`, EC2 ASG `cops-app-asg` (2× t3.micro)
  behind ALB `cops-alb`, CloudWatch observability.
- **Assumption for the "always-on" column:** 730 hours/month (a full month) so the
  estimate is a conservative upper bound. The lab is **not** actually run 24/7 (see
  *Build → demo → destroy* below), so real cost is a fraction of this.
- **Pricing basis:** on-demand, us-east-1, no reserved/savings plans, no free tier applied.

## Core stack — monthly estimate (always-on basis, 730 hrs)

| Line item | Est. unit price (us-east-1, on-demand) | Qty / usage | Est. monthly | Rationale (why this cost) |
|---|---|---|---|---|
| EC2 `t3.micro` (app tier) | ~$0.0104 /hr | 2 instances × 730 hr | **~$15** | Two always-on app instances in the ASG; two × ~$7.60/mo each. |
| EBS gp3 root volumes (EC2) | ~$0.08 /GB-mo | 2 × 8 GB | **~$1** | Small root disks for the two app instances. |
| ALB `cops-alb` — hourly | ~$0.0225 /ALB-hr | 730 hr | **~$16** | The load balancer bills a fixed hourly charge just to exist, independent of traffic. |
| ALB — LCU | ~$0.008 /LCU-hr | low lab traffic (~1–2 LCU) | **~$1–3** | LCUs scale with new connections, active connections, bandwidth, and rule evaluations; lab traffic is tiny, so this stays near the floor. |
| RDS `db.t3.micro` (Postgres, Single-AZ) | ~$0.017 /hr | 1 × 730 hr | **~$12** | Single-AZ managed Postgres instance running full-time. |
| RDS storage — 20 GB gp3 | ~$0.115 /GB-mo | 20 GB | **~$2** | Encrypted gp3 allocated storage for the database. |
| RDS backup storage | ~$0.095 /GB-mo beyond free allotment | ≤ ~20 GB retained | **~$0–2** | Backup storage up to 100% of provisioned DB storage is typically free; overage bills per GB. 7-day retention keeps this small. |
| CloudWatch Logs (`/cops/app`) ingest + storage | ~$0.50 /GB ingest, ~$0.03 /GB-mo stored | a few GB/mo lab volume | **~$1–3** | Low log volume in a lab; ingest dominates over storage at this scale. |
| CloudWatch alarms | ~$0.10 /alarm-mo | ~10 alarms | **~$1** | Standard-resolution metric alarms for the stack. |
| CloudWatch dashboard | ~$3 /dashboard-mo | 1 dashboard | **~$0–3** | First 3 dashboards can fall under the free allotment; budget ~$3 if billed. |
| Data transfer out | ~$0.09 /GB (after 100 GB free) | minimal lab egress | **~$0–1** | Almost no internet egress in a lab; intra-AZ/private traffic is cheap or free. |
| **Core stack subtotal (ESTIMATE, always-on)** | | | **~$50–55 / mo** | Upper-bound if left running 24/7 for a full month. |

> Rounding note: individual lines are rounded; the subtotal is a band, not a precise sum.

## Optional account-wide security services — **bills separately, only IF enabled**

These are gated behind the Terraform flag `enable_security_baseline` and are **off by
default**. They are **account-level**, so they bill independently of the lab stack and
**do not stop when you `terraform destroy` the app stack** — you must disable them
deliberately. Treat the numbers below as ballpark estimates that vary heavily with
account size and activity.

| Service | Est. billing basis | Est. monthly (small lab account) | Rationale |
|---|---|---|---|
| Amazon GuardDuty | per GB of analyzed logs (VPC Flow, CloudTrail, DNS) | **~$1–5** | Priced on volume of events analyzed; a quiet lab account produces little, but there is a real per-GB charge. |
| AWS Security Hub | per security check + per finding ingested | **~$1–5** | Bills per compliance check evaluated and per finding ingested from other services; scales with enabled standards. |
| AWS Config | per configuration item recorded + rule evaluations | **~$2–10** | Charges per config item recorded and per rule evaluation; can climb fast if recording many resource types. |
| Amazon Inspector | per instance-hour scanned + per image scanned | **~$1–5** | Continuous vuln scanning priced per EC2 instance and per container image; 2 instances keeps it modest. |
| **Security baseline subtotal (ESTIMATE, IF enabled)** | | **~$5–25 / mo** | Wide band — **only** incurred while the flag is on. Turn off after the security-findings drill. |

> **Honesty flag:** security-service pricing is usage-metered and account-specific.
> These are order-of-magnitude estimates only. Enable, observe actual spend in Cost
> Explorer for a day, then decide.

## Build → demo → destroy (how the lab is actually run)

The lab is **not** a 24/7 environment. The intended lifecycle per working session is:

1. **Build** — `terraform apply` to stand up the full stack.
2. **Demo / drill** — run the incident, restore, and observability exercises (typically
   a few hours).
3. **Destroy** — `terraform destroy` to tear the stack back down.

Because the core stack is billed largely by the hour (EC2, ALB, RDS), **real cost tracks
hours-running, not the 730-hour always-on estimate above.** As a rough rule of thumb, a
handful of multi-hour sessions per month costs a small single-digit fraction of the
always-on band — e.g. running the stack ~20 hours in a month is roughly `20 / 730 ≈ 3%`
of the hourly-billed lines. This is an estimate; confirm against the actual bill.

> Caveat: `terraform destroy` tears down the **app stack**. It does **not** disable the
> account-wide security services (they are managed by the gated flag and are account-level)
> and does not delete retained RDS backups outside the stack. Verify both after teardown.

## Non-prod scheduling savings (methodology)

For the periods where the stack must stay up but is idle (nights/weekends in a would-be
non-prod environment), the biggest lever is **scaling the ASG to 0** off-hours.

**Method:**

1. Identify the always-on/idle EC2 cost — here ~2× t3.micro ≈ **~$15/mo** (plus small EBS).
2. Define a "business-hours" window. Example: 12 hrs/day × 5 days = 60 hrs/week ≈ **~36%**
   of the 168-hour week; the other **~64%** is off-hours.
3. Scale `cops-app-asg` desired capacity to **0** during off-hours (e.g. a scheduled
   scaling action) and back to 2 for business hours.
4. **Estimated EC2 saving ≈ the off-hours fraction of EC2 cost ≈ ~60–65% of the EC2 line.**
   On ~$15/mo of EC2 that is roughly **~$9–10/mo saved** on compute — an estimate.

**Important scoping caveats (so the saving is not overstated):**

- Scaling the ASG to 0 saves **only the EC2 (and its EBS) cost.** The **ALB hourly charge
  and the RDS instance keep billing** whether or not any app instances are running — those
  are not reduced by ASG scheduling. To cut those too you would stop/schedule the RDS
  instance and remove the ALB, which changes availability characteristics.
- Therefore, "scale ASG to 0 off-hours" saves roughly **~60% of the EC2 line**, which is a
  smaller slice of the *total* stack. It is a right-sizing habit worth demonstrating, not a
  headline whole-stack discount.
- For a lab that is destroyed between sessions, **`terraform destroy` already achieves ~100%
  savings** during downtime and is the primary cost control; scheduling is the pattern you
  would use in a persistent non-prod account.

All savings figures here are **estimates** derived from list prices and the assumed
schedule; actual savings depend on the real off-hours window and billed usage.
