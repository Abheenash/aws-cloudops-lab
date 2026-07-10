# Security findings

The account-wide security services that produce these findings — **GuardDuty,
Security Hub, Inspector v2, and AWS Config** — are defined in
[`terraform/security.tf`](../terraform/security.tf), gated behind the
`enable_security_baseline` flag. That flag is **OFF by default** (the services
are account-level and bill separately), so **no findings exist until it is
enabled**.

To run the drill: set `enable_security_baseline = true`, apply, let the services
generate findings, then triage each one here using
[`triage-template.md`](./triage-template.md).

> Record real findings only — one file per finding, or a running log. Do not
> pre-populate with fabricated results. See the [roadmap](../README.md#roadmap).
