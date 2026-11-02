# Postmortem — claim documents stopped processing (Oct 13–14, 2026)

**Status:** resolved
**Severity:** SEV-1 — customer-facing: claim uploads stuck, 40+ support tickets
**Affected window:** ~17:45 WIB Oct 13 → restored late night Oct 13/early Oct 14 (exact time filled in at completion)
**Author:** Platform engineer

## Impact

Claim documents uploaded by customers were not processed from Tuesday evening onward.
Customers saw claims stuck at "documents uploaded"; support had 40+ tickets by ~01:38 WIB
Wednesday. No data loss: the queue kept every message (retention 4 days, DLQ in place).
Backlog at discovery: ~48,200 messages, draining after restore.

Internal: one engineer on the incident overnight; customer support absorbing complaints;
the claims team blocked from verifying their new submission flow.

## Timeline

Times are WIB (UTC+7) unless marked UTC — cluster/app logs are UTC.

| Time | Event |
|---|---|
| Tue 13 Oct 07:21–08:29 UTC | Monthly report job runs big scans on `claim_documents`; slow dashboard queries reported on #claims-eng. **Unrelated** — ended hours before the outage. |
| Tue 13 Oct 17:38 WIB (10:38 UTC) | Dimas commits "rename service account to claims-worker-sa" (Helm values only). |
| Tue 13 Oct ~17:40–17:55 WIB | `helmfile apply` from a laptop; first run timed out on a flaky VPN, second reported "nothing to change". New ReplicaSet rolls out pods with SA `claims-worker-sa`. |
| Tue 13 Oct ~17:44 WIB (10:44 UTC) onward | New pods crash-loop: STS `AccessDenied` on `AssumeRoleWithWebIdentity`. Autoscaler keeps creating replacements; all fail. No page fires. |
| Wed 14 Oct 18:12 UTC (01:12 WIB) | CloudWatch alarm `claims-documents-oldest-message-age` enters ALARM state. **Alarm actions empty — nobody is notified.** |
| Wed 14 Oct 01:38 WIB (Tue 18:38 UTC) | Customer support reports stuck claims; tickets accumulate through the night. |
| Wed 14 Oct 02:10 WIB (Tue 19:10 UTC) | Rina pings platform; incident work begins. |
| Wed 14 Oct ~03:30 WIB | Root cause found; trust policy fixed in code and applied to prod; first pod verified healthy; rollout completes; backlog draining. |

## Root cause

The prod claims-worker pods authenticate to AWS via IRSA. The IAM role `claims-worker-prod`
trusts exactly one OIDC subject: `system:serviceaccount:claims:claims-worker`. On Tuesday the
Helm values were changed so pods use service account `claims-worker-sa`, but the IAM trust
policy was never updated (it lives in Terraform:
`live/acme/ap-southeast-3/claims/prod/claims-worker-iam`). New pods presented a subject the
role doesn't trust and failed with 403 on their first AWS call, at startup.

Contributing factors:

1. **Two-system change without coupling.** The SA name lives in Helm values; the trust policy
   lives in Terraform. Nothing checks that they match, and the rename went straight to prod
   from a laptop, over an unstable VPN, with no review — the second `helmfile apply`'s
   "nothing to change" was read as confirmation even though the first run had actually failed midway.
2. **No delivery path on the alarm.** The queue-backlog alarm existed and fired ~8 hours before
   customers noticed, but had no notification target configured.
3. **No signal from the workers themselves.** 30 crash-looping pods produced no page-worthy metric of their own while the queue was still filling.

## Why we only found out from customers

The alarm fired; it just had nowhere to go (`alarm_actions = []`). Secondarily, the failure
mode itself (CrashLoopBackOff) has no configured alert at all. Detection depended entirely on
customer pressure arriving ~24 hours after the first failed pod.

## Follow-up actions (owner: me — sole platform engineer; prioritized for that)

| # | Action | Priority / when | Status |
|---|---|---|---|
| 1 | Alarm gets a real destination: SNS topic wired into `alarm_actions` in code (`modules/sqs-queue`, prod enabled); subscribe the ops channel and an on-call phone number. | High — this week, ~0.5 day (mostly done in code) | In progress |
| 2 | Crash-loop detection: CloudWatch `KubePodCrashLoopBackOff` alarm on the claims namespace → same topic. Pages a dead worker before queue metrics move. | High — within 2 weeks | Planned |
| 3 | Change process for prod cluster apps: CI check + reviewed deploy step instead of direct laptop applies; cross-file note that an SA rename must ship with the IRSA trust-policy change (comment added in both places). | Medium — next few weeks, part of task 04 design | Planned |
| 4 | Rotate the `claims` DB password (plaintext in values file and git history); then move secrets out of the repo. | High for security, not needed for restore — within the week | Planned |
| 5 | Fix guardduty-2slack Lambda crash on non-EC2 findings + tests for S3/IAM fixtures (the Oct 9 S3 exfiltration finding never reached #security-alerts). | Medium — small fix | Done in code this submission |

## What would have prevented this

Any one of: an alarm with a destination, crash-loop alerting, or CI validating that the
Helm service-account name and the IRSA trust policy match. The cheapest was already half-built
(the alarm) — so we're finishing that first.
