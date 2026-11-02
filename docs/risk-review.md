# Risk review — first week as platform owner (task 01)

What I inherited, what it means for this business, and what I'd do about it.
Prioritized by *business impact if it happens next*, not by how annoying it is.
Effort estimates assume me alone; everything here can be verified from the repo
(the only exception is item 9 — state drift — which needs AWS access).

## Priority 1 — fix this week

### 1. Plaintext secrets in git (DB password, Slack webhook)

**What:** `apps/acme-prod-cluster/values/claims-worker.yaml` contains the prod
Postgres password in clear text; `live/.../platform/prod/guardduty-2slack`
contains the Slack webhook URL. Both are in git history and my fork is public,
so treat them as compromised.

**Why it matters here:** this is an insurer — that database holds claim data
(KTP numbers, medical documents) under OJK supervision and PCI-DSS-style
expectations. A leaked prod DB credential is exactly the kind of finding an
auditor writes a letter about. The Slack webhook leaks our internal alerting
channel (and anyone with it can post to it).

**Work:** rotate the DB password (~1h including app redeploy), move it out of
values into a secret mechanism (SOPS + helm-secrets is the honest path — Budi's
docs claim it exists but there is no `.sops.yaml` in the repo; I'll either set
that up properly or use cluster Secrets from SOPS-encrypted values), rotate the
webhook, and add a pre-commit/CI secret scan so this stops recurring.

**Rollout:** dev first to prove the path, then prod during a quiet window with
the app owner on call.

### 2. No crash-loop / liveness alerting on workloads

**What:** the only prod alarms are queue-based. A dead pod fleet (like the Oct 14
incident) produces no page until the queue fills up — or until customers call.

**Why it matters here:** claim processing is the core revenue path; every hour
of unnoticed outage = hundreds of stuck customer uploads and support tickets.

**Work:** CloudWatch `KubePodCrashLoopBackOff` + `KubePodNotReady` alarms for
the claims namespace → same SNS topic the queue alarm now uses (done in task 02).
~1 day including testing the page path.

### 3. Prod worker IAM policy is `sqs:*` on all resources

**What:** `live/.../claims/prod/claims-worker-iam` allows every SQS action on
`*`. The dev stack shows the intended shape (specific actions, specific queue ARN).

**Why it matters here:** least privilege is table stakes for OJK and for our own
blame isolation — this role could delete or read any queue in the account.

**Work:** copy the dev pattern: `sqs:ReceiveMessage/DeleteMessage/ChangeMessageVisibility/GetQueueAttributes`
on `claims-documents` + its DLQ. Low risk (worker only uses those), easy rollback.

### 4. Deliver the queue alarm end-to-end

**What:** done in code (task 02) — the SNS topic exists and is wired into
`alarm_actions`. The manual part: subscribe the ops Slack channel and an on-call
phone number to that topic, then fire a test message and confirm someone gets paged.

**Work:** ~15 min once I'm in the account; the only thing between us and "customers
don't find out anymore" is this subscription.

### 5. Rotate Budi's AdministratorAccess key

**What:** `docs/deploy.md` says my access model *is* an admin IAM user with a key
in 1Password, and that Budi's key should be reused after his departure. Admin keys
for people who may still have the password are how accounts get emptied at 3am.

**Work:** rotate/retire the key today; give myself least-privilege access for real
tasks (see item 10); document the break-glass process.

## Priority 2 — next two weeks

### 6. Long-lived IAM user with `s3:*` in prod (`claims-reports-uploader`)

**What:** an IAM **user** with a permanent access key and `s3:*` on the reports
bucket, made because "the claims team wanted keys for laptop scripts." GuardDuty
already flagged anomalous behavior from this exact identity (Oct 9 exfiltration
finding — which also never reached Slack, see item 8).

**Why it matters here:** customer-facing data in a bucket that one human key can
read/write unconditionally; the finding pattern suggests misuse is plausible.

**Work:** freeze the key, audit recent usage from CloudTrail (also answers "what
did this key actually touch"), then replace with what the team actually needs —
temporary credentials via a small scoped role, or S3 presigned URLs from the app.

### 7. Prod image tag is `latest`, no pinning, no deployment trail

**What:** `apps/acme-prod-cluster/values/claims-worker.yaml` uses `tag: latest`;
the claims team "pushes to ECR and restarts." No immutable ref, no record of what's
running in prod.

**Why it matters here:** if a bad OCR model or config lands in ECR, there is no
safe way to answer "what version was serving claims at 14:00?" — and no fast
rollback that isn't a guess. Regulators will ask exactly this after an incident.

**Work:** pin prod to immutable digests; make image pushes go through CI (tag from
commit SHA); document the rollback command in the runbook.

### 8. GuardDuty→Slack coverage gap (code done, verify + threshold)

**What:** `modules/guardduty-2slack` only worked for EC2 findings — any S3/IAM/ECR
finding crashed the Lambda before posting. Fixed in code with tests (task 02).
Remaining: deploy the new Lambda to prod, and sanity-check `min_severity = 4`
against the severity scale the account actually uses — I want MEDIUM+ delivered,
not accidentally filtering criticals.

**Work:** ~30 min apply + a synthetic finding test per type (I have the fixtures).

### 9. State drift audit — "repo is not the truth"

**What:** `docs/deploy.md` says applies happen from a laptop and commits follow
"whichever" order, so live AWS may not match this repo. Nobody has diffed them.

**Why it matters here:** every other risk item assumes the repo describes reality;
if prod was hand-tweaked by Budi (or by product engineers' laptop applies), my
plans above may be wrong.

**Work:** one focused session: `terragrunt state pull` per stack vs actual resources,
drift report, converge or document deltas. ~1 day. I'm scheduling this before any
other live change touches prod.

### 10. Access model: no MFA-gated human access story, admin keys everywhere

**What:** humans use IAM user + key; CI has *no* credentials yet (Budi was going to
add a GitHub Actions IAM user with static keys in repo secrets — that's also bad).

**Why it matters here:** OJK will ask "who changed production, who approved it";
with admin keys and no trail we can't answer. Static GitHub keys mean the same
admin-level blast radius leaks through one repo secret.

**Work:** humans → IAM Identity Center / SSO + MFA (drop long-lived human keys);
automation → GitHub OIDC federated role scoped per job; break-glass admin documented
and logged. This is the foundation for task 04 — I'm starting it in week 2, not
inventing it from scratch later.

## Priority 3 — within 90 days

### 11. Docs are wrong about the platform (ArgoCD, Karpenter, SOPS, PagerDuty)

`docs/architecture.md` describes tools we don't run: deployments are helmfile from
a laptop (no ArgoCD), nodes use cluster-autoscaler (not Karpenter), secrets are
plaintext values (no SOPS/helm-secrets despite the claim), paging is... nothing
(alarm actions were empty). Docs that lie are worse than no docs — they sent me
down the wrong path for an hour. Rewrite them to describe reality as part of the
task 04 work; "assume nothing he wrote is true" should be our standing rule until
then.

### 12. Single account, single region for dev and prod

**What:** one AWS account (`111111111111`) hosts dev + prod, no separate
environments at the IAM/VPC boundary beyond naming.

**Why it matters here:** a prod admin key (or a confused product engineer with
write access) can touch dev and prod alike; there is no compliance boundary for an
insurer to point at regulators. Not something I fix this month — it's an
account/architecture project — but the direction (at minimum: prod in its own
account, or strict per-environment roles + SCPs) belongs in the 90-day plan.

### 13. No backups documented for claims-db

**What:** `docs/architecture.md` TODO admits it; nothing in the repo proves RDS
automated backups are on (RDS itself isn't even in this repo — it may be hand-made).

**Why it matters here:** losing claim data is an existentially bad day for an
insurer. **Work:** verify RDS automated backups + PITR, test one restore, document
RPO/RTO. Half a day of checks; cheap insurance.

### 14. Single NAT gateway in prod VPC

**What:** `live/.../platform/prod/vpc` has `single_nat_gateway = true`. It's a
known failure point: when it dies, private subnets lose egress (workers can't
reach SQS/RDS endpoints, ECR pulls fail).

**Work:** add NAT GW in a second AZ (third is nice-to-have). Low-risk change but it
touches the VPC module — do it deliberately, not opportunistically. ~half a day.

### 15. No DR story / RTO-RPO for claims processing

**What:** nothing in the repo or docs defines recovery objectives. The queue has
4-day retention and a DLQ, but there's no documented failover, no tested restore,
no "what do we tell customers if prod is down 6 hours" plan.

**Work:** write the DR doc for claims processing (the crown-jewel path), define
RTO/RPO with Rina, run one game day. This is the deliverable that makes OJK ask
fewer questions.

---

## What I fixed in code already (with task 02/03)

| Item | Where |
|---|---|
| IRSA trust policy ↔ SA name mismatch (the outage) | `live/.../claims/prod/claims-worker-iam` + coupling comment |
| Queue alarm had no notification target | `modules/sqs-queue` SNS topic + prod `alarm_actions` |
| GuardDuty Lambda dropped all non-EC2 findings | `modules/guardduty-2slack` + tests for S3/IAM fixtures |
| Claim documents storage (dev+prod) with scoped access | new buckets, uploader roles, worker read statements |

Deliberately **not** fixed in code yet: #1 (needs the live account to rotate),
#6 (needs CloudTrail audit first — freezing blind could break their reporting),
#9–#10 (design work; task 04).

## 90-day plan

**Days 1–7 (trust the foundation)**
- Finish P1 items: secrets rotation + secret scanning, crash-loop alerts, prod SQS
  policy scope-down, alarm subscription verified, Budi's admin key retired.
- Drift audit (#9) before any further live changes; fix or document deltas.
- Rewrite `docs/architecture.md` to match reality (start of #11).

**Days 8–30 (make changes safe and reviewable)**
- Access model: SSO + MFA for humans, OIDC for CI (#10); break-glass doc.
- Prod image pinning + CI-built tags (#7); runbook updated with rollback steps.
- Ship task 04's design (PR→prod for infra and cluster apps) and start rolling it
  out: finish `apply.yml` properly for one non-prod stack first.
- Reports-uploader replacement live, old key deleted (#6).

**Days 31–90 (compliance-grade operations)**
- Separate prod account (or at minimum hard SCP/role boundaries) — #12, with Rina
  and management on the cost/time trade-off.
- Claims-db backup verification + tested restore (#13), DR doc + game day (#15).
- Second NAT gateway (#14) during a planned window.
- Baseline SLOs for claim processing (queue age p95, processing latency, error
  rate) with dashboards — so "is it working" is a number, not a feeling.

**What I'll deliberately NOT do in 90 days:** multi-region DR, service mesh,
observability platform build-out (Prometheus/Grafana stack), custom tooling
beyond CI/CD. Budget is small and one engineer can't own all of it; buy time by
making the boring things reliable first.

## How I'd roll these out safely

- Dev/prod ordering always; prod changes during low traffic (claims volume is
  month-end-heavy — avoid the last 5 days of the month).
- Every live change: plan captured, rollback command written *before* apply,
  one pod/one stack canary where possible.
- Nothing touches prod without a CI-green commit first — the moment `apply.yml`
  works for dev, "laptop apply" is retired by policy even if some manual work
  remains.
