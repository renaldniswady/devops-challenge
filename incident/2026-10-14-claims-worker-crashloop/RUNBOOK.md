# Restore runbook — claims documents not processing (Oct 14, 2026)

For the 02:10 page. Run in order; each step says what success looks like.

## What is actually broken

All `claims-worker` pods in prod crash on startup with:

```
ERROR sqs: ReceiveMessage failed: WebIdentityErr: failed to retrieve credentials
caused by: AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

The IRSA role `claims-worker-prod` trusts exactly one OIDC subject:
`system:serviceaccount:claims:claims-worker`. Since Tuesday ~17:40 WIB the pods
run with service account `claims-worker-sa` (renamed in Helm only), so every pod's
STS call returns 403 and it exits.

Not related, ruled out while triaging:

- The "slow queries" from Rina were the monthly report job (`reporting` user,
  Tue 07:21–08:29 UTC) — stopped hours before the outage.
- The SQS queue itself is healthy; it's just backing up (~48k messages).

## Restore (do this first)

1. **Confirm the mismatch** (no changes yet):

   ```bash
   aws iam get-role --role-name claims-worker-prod \
     --query 'Role.AssumeRolePolicyDocument' --output json
   ```

   Expect the sub condition to still say `system:serviceaccount:claims:claims-worker`.

2. **Apply the trust-policy fix** — this repo's diff in
   `live/acme/ap-southeast-3/claims/prod/claims-worker-iam/terragrunt.hcl`:

   ```bash
   cd live/acme/ap-southeast-3/claims/prod/claims-worker-iam
   terragrunt plan    # expect: aws_iam_role.this will be updated in place
   terragrunt apply
   ```

   Only the role's assume policy changes. No queue, no app, nothing destroyed.

3. **Prove one pod recovers before trusting the rollout:**

   ```bash
   kubectl -n claims get pods | grep claims-worker
   kubectl -n claims delete pod <one-crashlooping-pod>
   kubectl -n logs -f <new-pod>      # expect: db connected, sqs polling, no WebIdentityErr
   ```

   If the new pod still crashes: stop and roll back (below). Don't delete more pods.

4. **Let the rollout finish.** The ReplicaSet replaces pods as they go; autoscaling
   brings the count back toward 30. Watch:

   ```bash
   kubectl -n claims get pods --watch
   aws sqs get-queue-attributes \
     --queue-url https://sqs.ap-southeast-3.amazonaws.com/111111111111/claims-documents \
     --attribute-names ApproximateNumberOfMessages
   ```

5. **Verify it's draining and the alarm clears:**

   - `ApproximateNumberOfMessages` trending down (48k backlog takes a while at 30 pods × concurrency 4 — that's expected).
   - `aws cloudwatch describe-alarms --alarm-names claims-documents-oldest-message-age` → state `OK`.
   - Glance at the DLQ: messages that hit maxReceiveCount land there and need individual inspection before any redrive.

6. **Tell Rina** what happened, when it's fixed, and an ETA for the backlog based on the message-count trend.

## Rollback (if step 3 or 4 shows it didn't work)

The old service account name is still trusted by the role until this change lands, so
rolling back is cheap:

```bash
git checkout main -- apps/acme-prod-cluster/values/claims-worker.yaml   # in a throwaway branch
helmfile -f apps/acme-prod-cluster/helmfile.yaml sync
```

Pods come back as `claims-worker`, matching the existing trust policy. Re-investigate
from the new pod's logs before retrying the fix.

## Why nobody was paged

`claims-documents-oldest-message-age` entered ALARM at 11:12 UTC Tuesday — about 8
hours before customers noticed — but its `alarm_actions` list was empty. The alarm
worked; it just had nowhere to send the message.

## Follow-up actions (mine, in priority order)

| # | Action | Status / when |
|---|---|---|
| 1 | **Alarm gets a real destination.** Done in code: `modules/sqs-queue` now creates an SNS topic and prod passes its ARN into `alarm_actions`. Subscribing the ops channel + on-call phone is the remaining manual step (~10 min). | Mostly done, finish this week |
| 2 | **Detect dead workers, not just a dead queue.** Add a `KubePodCrashLoopBackOff` metric alarm for the claims namespace → same topic. Pages a crash-looping fleet even when queue metrics haven't moved yet. | ~1 day incl. testing |
| 3 | **Stop direct prod applies from laptops.** CI check + reviewed deploy step for `apps/`; note in both files that an SA rename must ship with the IRSA role change (comment added here). The failed VPN run on Tue was read as success because "nothing to change". | part of the task 04 design |
| 4 | **Rotate the `claims` DB password** — it sits in plaintext in `apps/acme-prod-cluster/values/claims-worker.yaml` and is now in git history. Move secrets out of values files after rotation. | within the week |
| 5 | **Fix the guardduty-2slack Lambda** — it crashed on any non-EC2 finding (`instanceDetails` only exists on EC2), so e.g. the Oct 9 S3 exfiltration finding never reached #security-alerts. Fixed in code with tests for the S3/IAM fixtures (see `modules/guardduty-2slack`). | done in this submission |
