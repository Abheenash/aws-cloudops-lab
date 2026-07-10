# Brownfield: `terraform import` + drift detection

The day-2 skill a greenfield repo can't show: taking a resource **someone created
by hand**, bringing it under Terraform, and then keeping it from drifting. Run live
on 2026-07-10 against a real S3 bucket, then destroyed.

`main.tf` declares one `aws_s3_bucket` with `tags = { Environment = "lab", ManagedBy = "terraform" }`.

## The exercise (real captured output)

**1. Create the bucket by hand** (unmanaged), with console-style tags:
```
$ aws s3api create-bucket --bucket cops-brownfield-638515252275 --region us-east-1
$ aws s3api put-bucket-tagging --bucket ... --tagging 'TagSet=[{Environment=manual},{Owner=console}]'
hand-created tags: Environment=manual  Owner=console
```

**2. Import it into Terraform state:**
```
$ terraform import aws_s3_bucket.brownfield cops-brownfield-638515252275
Import successful!
```

**3. `terraform plan` — reconcile the imported resource to config:**
```
  ~ tags = {
      ~ "Environment" = "manual" -> "lab"
      + "ManagedBy"   = "terraform"
      - "Owner"       = "console" -> null
    }
Plan: 0 to add, 1 to change, 0 to destroy.
```
Terraform now *sees* the hand-made resource and shows exactly how reality differs from the desired config.

**4. `terraform apply` — now fully managed:**
```
Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
managed tags: Environment=lab  ManagedBy=terraform
```

**5. Induce drift out-of-band** (as if someone clicked in the console):
```
$ aws s3api put-bucket-tagging --bucket ... --tagging 'TagSet=[{Environment=HACKED},{ManagedBy=terraform}]'
```

**6. `terraform plan` DETECTS the drift:**
```
  # aws_s3_bucket.brownfield will be updated in-place
  ~ tags = {
      ~ "Environment" = "HACKED" -> "lab"
    }
Plan: 0 to add, 1 to change, 0 to destroy.
```

**7. `terraform apply` REVERTS it** back to the declared state:
```
Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
reconciled tags: Environment=lab  ManagedBy=terraform
```

**8. Cleanup:**
```
$ terraform destroy -auto-approve
Destroy complete! Resources: 1 destroyed.
```

## Why it matters

- **Import** is how you adopt infrastructure that predates your IaC without recreating it (and causing an outage).
- **Drift detection** (`terraform plan`) is your early-warning that reality no longer matches code — the root cause of most "it worked yesterday" incidents.
- In production you'd run `plan` on a schedule (or in CI on every PR) so drift is caught automatically, and lock down console write access so config is the single source of truth.
