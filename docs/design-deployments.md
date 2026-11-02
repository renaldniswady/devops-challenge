# Design — getting the platform off one laptop (task 04)

_Two pages. Answers management's two questions: deployments must not depend on a
laptop, and we must be able to tell OJK who changed production, when, and who
approved it._

## Principles first

1. **Git is the system of record.** A change exists when it's merged to `main`,
   not when someone typed it into a console. Every prod change is reachable from
   exactly one merged PR — that PR *is* the OJK answer (who, when, what was reviewed).
2. **CI gates, humans approve, machines apply.** CI never applies. Humans review and
   approve (that's the audit record). A machine with a job-scoped identity applies.
3. **No long-lived secrets for automation.** If a key or token can be copied out of the
   org, it's admin-level exposure. Federated identities instead.
4. **One path per concern, no parallel paths.** Laptop applies become break-glass only;
   anything applied outside the pipeline must be reconciled into git within 24h (we'll
   have a weekly drift check that catches it).

## How a change reaches production

### Infrastructure (`live/`, Terragrunt + Terraform)

```
PR to main  →  CI (validate, fmt, tflint, checkov, plan diff posted to the PR)
             →  review: one approval required for prod-affecting changes
                (2 approvals if it touches IAM roles/policies or state moves)
             →  merge
             →  Apply workflow (triggered by merge): per-stack terragrunt apply,
                dev stacks first, then prod; any failure stops the run and pages us
```

Concretely, this means finishing Budi's `apply.yml` — which today is a WIP that
checks out a dead branch, uses static repo-secret keys, and applies *everything* in
one shot. The finished version: OIDC-federated role (per-environment permissions),
stack-by-stack apply in dependency order (platform → BU stacks), plan attached to the
run log for the audit trail, and a required status check so merges that can't be
applied don't slip through silently.

**Why merge-triggered rather than manual dispatch:** manual dispatch is exactly how
we end up with "someone applied from their laptop instead." A merge must produce an
apply (or a visible, logged skip) — the pipeline can't be bypassed without leaving a trace.

### Cluster apps (`apps/`, helmfile → EKS)

Same shape, rendered by Helm:

```
PR to main  →  CI (helm lint + template + kubeconform on every values file,
                schema-checked against the cluster's real API versions where possible)
             →  review/approval (same rules as infra; prod requires approval)
             →  merge
             →  Deploy workflow: helmfile diff posted to the run log, then
                helmfile sync for the targeted cluster (dev always; prod only after
                the approval is recorded in the merge)
```

Keeping **helmfile** rather than adopting ArgoCD here is a deliberate cost decision:
it's the tool already in the repo, CI already renders its output, and one engineer
can own it. The diff-then-sync pattern gives us the preview step ArgoCD would give.
If we outgrow it (multiple teams shipping concurrently, need for per-service rollback
UI), ArgoCD is the documented upgrade path — not a re-invention.

**Image rule (part of this design):** prod values must reference an immutable image
(digest or SHA tag built by CI from the app repo). `latest` in prod stops being legal
the day the CI check lands. This closes the "what version was serving claims at 14:00?"
question permanently.

## AWS access — humans and automation

| Who | Today | Target | Notes |
|---|---|---|---|
| Me (platform) | Admin IAM user + key in 1Password | SSO/Identity Center, MFA, least-privilege roles per area | Admin key retired now; break-glass admin exists, is logged, and is time-boxed |
| Product engineers | Laptop applies with shared access | No direct AWS apply rights for cluster values (CI deploys); read-only CloudWatch/console for their services | They keep write access to the repo — that's how they ship |
| Claims team | Human IAM user + long-lived key (`claims-reports-uploader`) | Scoped role assumed via SSO with MFA, short-lived session; or presigned URLs from the app | The existing key is frozen and being audited (task 01, #6) |
| CI (infra apply) | Static repo-secret keys (Budi's plan) | GitHub **OIDC** → IAM role scoped to `live/` apply needs only | No secrets in GitHub at all; role trust is our org's repo + branch protection |
| CI (app deploy) | — | Same OIDC pattern, second role scoped to the EKS `eks:DescribeCluster` + kubeconfig retrieval for the target cluster only | Prod deploy role additionally requires the merge to carry a review approval |
| Workloads in-cluster | IRSA | IRSA (already correct) | No change; we just add the coupling check (below) |

**Guardrail for the incident class we just had:** CI validates that every
`serviceAccount.name` in `apps/*/values/*.yaml` has a matching IRSA trust policy in
`live/` (a small script comparing the two trees). It's ~50 lines and it makes that
outage un-reproducible by accident.

## What I am deliberately NOT doing (yet), and why

- **Not ArgoCD now.** Adds a control-plane service to run, another identity to manage,
  and a migration of existing releases — real cost for a team where one person owns it
  all. helmfile + CI gets us 90% of the outcome at ~10% of the effort. Revisit when
  more than one team ships concurrently.
- **Not a separate prod account yet** (that's the 90-day arc, task 01 #12). The design
  above is written to be account-aware (everything flows through `account.hcl`), so
  the split later is config, not re-architecture.
- **Not mandatory 2-person approval for dev changes.** Reviewing every dev PR at a one-
  engineer company is theater; prod has the gate where it matters. If a contractor or
  second engineer joins, we tighten this day one.
- **Not a full observability platform.** We need alarms with destinations and SLO
  dashboards for claims — not Prometheus/Grafana/OTel build-out in the same window as
  everything above.
- **Not auto-remediation or fancy IaC pipelines (Atlantis-style, PRs per stack).**
  Over-engineering for current change volume; we can add it without breaking this design.

## Rollout plan (no business blocking)

1. **Week 1 — access first:** retire Budi's admin key, stand up SSO for humans, create
   the two OIDC roles (dev-scoped first). Nothing ships differently yet; we just stop
   holding keys.
2. **Week 2 — infra on the pipeline (dev):** finish `apply.yml` for dev stacks only
   (OIDC, per-stack, plan-in-log). Laptop applies for *dev* retire immediately; prod
   stays manual with a written runbook until step 3.
3. **Week 3–4 — apps on the pipeline:** CI deploy workflow for dev cluster (helmfile
   diff→sync), image-pin check lands, `latest` banned in prod values by CI. Product
   engineers' laptop applies to dev end here.
4. **Month 2 — prod cutover:** prod apply + deploy workflows go live behind the
   approval requirement; one real prod change is made through the pipeline as the
   dress rehearsal (candidate: the claims-documents buckets from task 03). Laptop
   becomes break-glass with a written procedure and 24h reconciliation.
5. **Month 2–3 — proof for OJK:** runbook page showing how to answer "who changed X,
   when, who approved" using git blame + GitHub review + CI run log; plus the weekly
   drift report proving repo == AWS.

Success criteria at the end: a prod change made entirely from a PR by someone other
than me, with zero console access used, and a 5-minute demonstration of the OJK query.
