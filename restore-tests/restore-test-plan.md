# Restore-Test Plan — `cops-db` (RDS Postgres)

A real, runnable backup/restore drill for the AWS Cloud Ops Lab. The point of this
document is to *prove* the automated backups can actually be restored inside a target
time — not to assume it. Run it, then fill in the **Results** table with measured values.

- **Region:** `us-east-1`
- **Source database:** `cops-db` (Postgres 16, `db.t3.micro`, 20 GB gp3, encrypted, 7-day automated backups)
- **Restore target:** a NEW instance `cops-db-restore` (never restore over the live DB)
- **Master user:** `copsadmin` (password is managed in AWS Secrets Manager, not in code)
- **Initial database:** `copsdb`

## Objectives (RTO / RPO)

| Metric | Target | Basis |
|---|---|---|
| **RTO** (Recovery Time Objective) | **60 minutes** | Time from starting the restore to a validated, queryable `cops-db-restore`. This is what the drill measures. |
| **RPO** (Recovery Point Objective) | **Up to 24 hours; never older than 7 days** | Automated snapshots run daily in the `07:00–07:30 UTC` backup window with 7-day retention. Worst-case data loss is the gap back to the most recent daily snapshot (≤ ~24h); the oldest recoverable point is 7 days. Point-in-time recovery (PITR) can tighten this to ~5 minutes but is out of scope for this snapshot drill. |

> RTO is a **measured** result of this drill. RPO is a **property of the backup config**
> (7-day automated snapshots) and does not need re-measuring each run.

## Pre-flight

```bash
export AWS_REGION=us-east-1
export SRC=cops-db
export TGT=cops-db-restore

# Confirm the source DB exists and note its class/storage for an apples-to-apples restore.
aws rds describe-db-instances \
  --db-instance-identifier "$SRC" \
  --region "$AWS_REGION" \
  --query 'DBInstances[0].{Class:DBInstanceClass,Storage:AllocatedStorage,SubnetGroup:DBSubnetGroup.DBSubnetGroupName,SGs:VpcSecurityGroups[].VpcSecurityGroupId,Encrypted:StorageEncrypted}'
```

Record the `DBSubnetGroup` and security-group IDs — the restored instance must land in the
same private subnets and RDS security group so it stays private and reachable from the app tier.

## Step 1 — List automated snapshots for `cops-db`

```bash
aws rds describe-db-snapshots \
  --db-instance-identifier "$SRC" \
  --snapshot-type automated \
  --region "$AWS_REGION" \
  --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[].{Id:DBSnapshotIdentifier,Created:SnapshotCreateTime,Status:Status}' \
  --output table
```

Pick the **most recent `available`** snapshot and capture its identifier:

```bash
export SNAP=$(aws rds describe-db-snapshots \
  --db-instance-identifier "$SRC" \
  --snapshot-type automated \
  --region "$AWS_REGION" \
  --query 'reverse(sort_by(DBSnapshots[?Status==`available`],&SnapshotCreateTime))[0].DBSnapshotIdentifier' \
  --output text)
echo "Using snapshot: $SNAP"
```

## Step 2 — Start the restore (record the start time)

```bash
export RESTORE_START=$(date -u +%FT%TZ)
echo "Restore start: $RESTORE_START"

aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier "$TGT" \
  --db-snapshot-identifier "$SNAP" \
  --db-instance-class db.t3.micro \
  --db-subnet-group-name <cops-db-subnet-group> \
  --vpc-security-group-ids <cops-rds-sg-id> \
  --no-publicly-accessible \
  --no-multi-az \
  --region "$AWS_REGION"
```

Substitute `<cops-db-subnet-group>` and `<cops-rds-sg-id>` with the values captured in
Pre-flight. The restored instance keeps the source's encryption and the same master
username; its master password is available via the RDS-managed Secrets Manager secret.

## Step 3 — Wait until available (this is the bulk of the RTO)

```bash
aws rds wait db-instance-available \
  --db-instance-identifier "$TGT" \
  --region "$AWS_REGION"

export RESTORE_AVAILABLE=$(date -u +%FT%TZ)
echo "Available at: $RESTORE_AVAILABLE"
```

## Step 4 — Validate with a query

Get the endpoint and the managed password, then run a liveness query and a row count.

```bash
export EP=$(aws rds describe-db-instances \
  --db-instance-identifier "$TGT" --region "$AWS_REGION" \
  --query 'DBInstances[0].Endpoint.Address' --output text)

export SECRET_ARN=$(aws rds describe-db-instances \
  --db-instance-identifier "$TGT" --region "$AWS_REGION" \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)

export PGPASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" --region "$AWS_REGION" \
  --query 'SecretString' --output text | python3 -c 'import sys,json;print(json.load(sys.stdin)["password"])')

# Liveness check.
psql "host=$EP port=5432 dbname=copsdb user=copsadmin sslmode=require" -c "SELECT 1;"

# Data-present check: count rows in every user table (proves real data came back, not an empty shell).
psql "host=$EP port=5432 dbname=copsdb user=copsadmin sslmode=require" -c \
"SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC;"
```

> This must be run from inside the VPC (a bastion, an app-tier EC2 host, or SSM
> port-forwarding) because `cops-db-restore` is not publicly accessible.

## Step 5 — Record the measured RTO

```bash
python3 - <<'PY'
import os,datetime
s=datetime.datetime.fromisoformat(os.environ['RESTORE_START'].replace('Z','+00:00'))
a=datetime.datetime.fromisoformat(os.environ['RESTORE_AVAILABLE'].replace('Z','+00:00'))
mins=(a-s).total_seconds()/60
print(f"Measured RTO: {mins:.1f} min  ->  {'PASS' if mins<=60 else 'FAIL'} vs 60-min target")
PY
```

## Step 6 — Tear down the restored instance

The restored copy is a throwaway. Delete it as soon as validation is recorded so it
does not accrue cost.

```bash
aws rds delete-db-instance \
  --db-instance-identifier "$TGT" \
  --skip-final-snapshot \
  --delete-automated-backups \
  --region "$AWS_REGION"

aws rds wait db-instance-deleted \
  --db-instance-identifier "$TGT" \
  --region "$AWS_REGION"
```

Confirm it is gone:

```bash
aws rds describe-db-instances --region "$AWS_REGION" \
  --query 'DBInstances[?DBInstanceIdentifier==`cops-db-restore`].DBInstanceIdentifier' --output text
```

## What to do if the restore fails

If the restore does not complete, does not become `available`, or the validation query
fails, the drill is a **FAIL** — record it honestly (that is the whole point) and act:

1. **Capture the reason.** Check instance status and events:
   `aws rds describe-events --source-identifier cops-db-restore --source-type db-instance --region us-east-1`.
2. **Common causes and fixes:**
   - *Subnet-group / AZ mismatch* — ensure the DB subnet group has subnets in the required AZs.
   - *KMS access denied* — the caller needs `kms:Decrypt`/`CreateGrant` on the key that encrypted `cops-db`.
   - *Security group / connectivity* — validation must run from inside the VPC; confirm the RDS SG allows 5432 from the app SG.
   - *No snapshot available* — if `describe-db-snapshots` returns nothing, backups are effectively broken; escalate immediately and treat as a Sev-high finding.
3. **Do not delete the source.** `cops-db` is untouched by this drill; never "fix" a failed restore by touching production.
4. **Re-run** after the fix, and log both the failed and the successful attempt in the Results table.
5. **File an action item** (see the monthly report) with an owner and a due date.

---

## Results — fill after execution

Leave every cell as `<fill after run>` until the drill has actually been executed. Do not
pre-fill measured values.

| Field | Value |
|---|---|
| Date/time of drill (UTC) | `<fill after run>` |
| Operator | `<fill after run>` |
| Snapshot ID used | `<fill after run>` |
| Snapshot creation time | `<fill after run>` |
| Restore start time (UTC) | `<fill after run>` |
| Available time (UTC) | `<fill after run>` |
| **Measured RTO (min)** | `<fill after run>` |
| **Pass/Fail vs 60-min target** | `<fill after run>` |
| Validation query result (SELECT 1) | `<fill after run>` |
| Row-count sanity check | `<fill after run>` |
| Restored instance torn down? (Y/N) | `<fill after run>` |
| Notes / anomalies | `<fill after run>` |
