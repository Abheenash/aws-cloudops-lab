# Restore Tests

A backup you have never restored is a hope, not a backup. Snapshots that show up green in
the console tell you a *file* exists; they say nothing about whether that file can be turned
back into a running, queryable database inside a time your business can survive. Timed
restore drills close that gap: by actually restoring `cops-db` to a throwaway instance,
validating it with a real query, and measuring the recovery time against a stated RTO
(60 minutes), we convert an assumption into evidence — surfacing broken KMS grants, subnet
misconfigurations, missing snapshots, or a restore that simply takes longer than we can
afford *before* an incident forces the discovery. See
[`restore-test-plan.md`](./restore-test-plan.md) for the runnable drill and the results
table to fill in after each execution.
