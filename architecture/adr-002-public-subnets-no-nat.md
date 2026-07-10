# ADR-002: App instances in public subnets, no NAT gateway

Status: Accepted
Date: 2026-07-10

## Context

The app instances need **outbound** internet access — to install packages
(yum/pip) at boot, to reach the SSM endpoints for Session Manager and Patch
Manager, to read the database secret from Secrets Manager, and to ship logs and
metrics to CloudWatch. They do **not** need to be directly reachable from the
internet; all inbound traffic arrives through the ALB.

The standard production pattern is to put the app tier in **private subnets** and
give it outbound access via a **NAT gateway** (or reach AWS services through VPC
interface/gateway endpoints). Both cost real money and run continuously:

- A NAT gateway bills an hourly rate **plus** per-GB data processing, per AZ, for
  as long as it exists.
- A full set of interface endpoints (SSM, SSM Messages, EC2 Messages, Secrets
  Manager, CloudWatch, logs, …) bills per endpoint per AZ per hour.

This lab is **built to be created and destroyed repeatedly**, and has a `$20`
monthly budget guardrail. Paying a NAT gateway's standing cost across every
build cycle is disproportionate to the value for a throwaway environment.

## Decision

Run the app instances in the **public subnets** with a public IP, so their
outbound traffic goes straight through the internet gateway, and **omit the NAT
gateway and interface endpoints entirely**. Lock down exposure at the security
group instead of at the subnet:

- `cops-app-sg` allows inbound **only** on port 8080 and **only** from
  `cops-alb-sg` — the ALB is the sole source that can reach the app port.
- **No SSH rule exists** on the app security group.
- Access to instances is **SSM-only** (Session Manager over the SSM agent), via
  the `AmazonSSMManagedInstanceCore` role — no key pairs, no bastion.
- **IMDSv2 is required** (`http_tokens = required`) to blunt SSRF-style
  credential theft.
- RDS stays in the **private subnets** with no internet route and a security
  group that accepts 5432 only from the app tier.

## Consequences

Positive:

- No NAT gateway or interface-endpoint standing cost — the build→destroy cycle
  stays cheap and fits the budget guardrail.
- Simpler network: one public route table to the IGW, one private route table
  with no default route.

Negative / trade-off (stated honestly):

- The instances have **public IPs**, which is a larger conceptual exposure than
  the standard private-subnet + NAT pattern. If a security-group rule were ever
  misconfigured to open a port to `0.0.0.0/0`, the host would be directly
  reachable — whereas in a private subnet it would not be, regardless of the SG.
  The compensating controls above (SG limited to the ALB, no SSH, SSM-only,
  IMDSv2) are what make this acceptable **for a lab**, and this is explicitly not
  the pattern to copy into production.
- Outbound egress is open (`0.0.0.0/0`) rather than constrained to specific AWS
  endpoints, accepted for the same lab-scoped reason.

For a production deployment, prefer private subnets with NAT (or interface
endpoints) and no public IPs; that cost is worth paying when the environment is
long-lived.
