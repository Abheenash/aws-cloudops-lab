# Configuration management for the app fleet

The lab's EC2 tier was built by a **100-line bash `user_data` script**
(`terraform/user_data.sh.tftpl`). That script works, and it is also exactly the
kind of thing you inherit: it ran once, at boot, as root, and it has no opinion
about what the instance looks like now.

That is the brownfield problem this directory solves. Terraform still owns the
infrastructure; Ansible owns what runs on it.

## What `user_data` cannot do, and this can

| | `user_data` | Ansible |
|---|---|---|
| Re-run to repair a drifted instance | ❌ boot-time only | ✅ idempotent, run any time |
| Tell you *whether* an instance has drifted | ❌ | ✅ `--check --diff` reports it |
| Converge a fleet that is already running | ❌ requires instance replacement | ✅ |
| Change one config value | ❌ new launch template + rolling replace | ✅ re-run the play |
| Run as a non-root service account | ❌ everything was root | ✅ `copsapp` system user |

## Fixes made while porting it

Porting a bash script to a role surfaces the things the script was quietly doing
wrong:

- **`pip install` as root into the system interpreter** → a virtualenv at
  `/opt/app/venv`. Installing Flask into the same Python that `dnf` depends on is
  how you break package management six months later.
- **The service ran as root** → a dedicated `copsapp` system account with
  `nologin`, plus `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp` and an
  explicit `ReadWritePaths` in the unit file.
- **The CloudWatch agent config was re-applied on every boot** → a handler, so it
  only fires when the template actually changed.

## Connection model

There is no inbound SSH and no key pair — the instances are IMDSv2-only with a
security group that does not open 22. Ansible connects over **SSM Session
Manager** (`ansible_connection: aws_ssm`), which is how a properly locked-down
fleet is reached in practice and needs no bastion.

Inventory is dynamic (`inventory/aws_ec2.yml`): the fleet is an autoscaling group,
so a static host list is wrong the moment it scales. Hosts are discovered by the
same `Patch Group` tag Terraform sets and SSM Patch Manager consumes — one source
of truth for "what is the app".

## Running it

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml -p ./collections

# values come from Terraform, so there is one owner for each
export COPS_DB_SECRET_ARN=$(terraform -chdir=../terraform output -raw db_secret_arn)
export COPS_DB_HOST=$(terraform -chdir=../terraform output -raw db_host)

ansible-playbook playbooks/site.yml                    # converge
ansible-playbook playbooks/drift-check.yml --check --diff   # report drift only
```

## Verified

`ansible-lint` passes at the **production** profile (its strictest) and
`ansible-playbook --syntax-check` parses cleanly. Both run in CI —
`.github/workflows/ci.yml` and the `Jenkinsfile` — so the two pipelines gate the
same thing.

**Not applied against live instances.** The lab is destroyed between drills, so
these roles are linted and syntax-checked, not run. The `--check` drift workflow
is the part that would need a live fleet to demonstrate.
