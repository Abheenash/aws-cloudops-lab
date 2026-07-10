# ADR-001: EC2 Auto Scaling Group over ECS/Fargate for the app tier

Status: Accepted
Date: 2026-07-10

## Context

The app tier could run as containers on ECS/Fargate or as EC2 instances in an
Auto Scaling Group. For most greenfield services, Fargate is the easier choice:
no hosts to patch, no OS to manage, less operational surface.

But the whole point of this repo is **day-2 operations** — the practice and
evidence of running a system after it's live, not just standing it up. The
drills this lab is built to support are:

- **SSM Patch Manager** patch-compliance runs against a `Patch Group` tag.
- **Linux-level troubleshooting** over Session Manager — inspecting the running
  Flask process, reading system/agent logs on the box, checking the CloudWatch
  agent, diagnosing a wedged instance.
- **Instance-failure and recovery drills** — terminate a host and watch the ASG
  relaunch it and re-register it behind the ALB.

Fargate abstracts the host away, so it cannot demonstrate any of the above:
there is no OS to patch with Patch Manager, no instance to shell into for
Linux-level debugging, and no instance lifecycle to fail and recover.

## Decision

Run the app tier on **EC2 instances in an Auto Scaling Group** (`cops-app-asg`,
Amazon Linux 2023, launch template with an SSM + CloudWatch instance profile and
the `Patch Group = cops-app` tag), fronted by the ALB, **not** on ECS/Fargate.

## Consequences

Positive:

- Patch Manager, Session Manager troubleshooting, and instance failure/recovery
  drills are all directly exercisable — the exact skills this lab is meant to
  produce evidence for.
- The instance is a real, inspectable Linux host: OS logs, the Flask process,
  and the CloudWatch agent are all on the box.

Negative / trade-off:

- There is **more to patch and manage** — an OS, the agent, and the app runtime,
  rather than a managed container platform. In a production service that would be
  a cost to weigh against Fargate's simplicity. **Here it is exactly the point:**
  that management surface is the thing being practiced, so the trade-off is
  accepted deliberately.
- Slightly slower scale/replace cycles than Fargate (instance boot + user-data
  vs. task start), which is acceptable for a lab.
