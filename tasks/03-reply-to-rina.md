# Reply to Rina — claim document storage (task 03)

_Draft of what I would actually send her._

---

Hi Rina,

Good news: the storage is built and ready for you to start testing in dev this week.

**What's in place**

- S3 buckets for the documents:
  - dev: `acme-claim-documents-dev`
  - prod: `acme-claim-documents-prod` (created, but not wired up until the flow ships there)
- Both have versioning on, so nothing is ever hard-deleted.
- The claims-worker can already read from both buckets — I scoped its IAM role to
  `GetObject` + `ListBucket` only, and added a `DOCUMENTS_BUCKET` env var to the
  worker in dev and prod values. So when you point the OCR step at that bucket it'll work.

**One thing I did differently from what you asked, and why**

You asked for an IAM user with access keys "like Budi did for the reports bucket".
I didn't do that, for three reasons:

1. **Long-lived keys are a liability.** We already have GuardDuty findings about exactly
   that pattern (the reports-uploader key triggered an anomalous-access alert on Oct 9).
   A human-held access key that can write to prod is the kind of thing we'd be explaining
   to OJK, not something I want to multiply.
2. **The backend should get a scoped role, not a key.** The app's upload path can run as an
   EKS service account (`claim-documents-uploader`) with only `s3:PutObject` on the
   bucket — no keys in env vars or laptops at all. If your backend runs inside the cluster,
   this is strictly better and it's already set up in dev.
3. **For the laptop scripts**, I'd rather give you temporary credentials (a small IAM role
   the script assumes via MFA / `aws sso`-style flow) than a permanent key. If that's too
   much friction for this week, the compromise: we can create a dev-only scoped user whose
   keys **expire** and only have `PutObject` on the dev bucket — never prod. Happy to set
   that up today if it unblocks you.

**What I need from you / product to finish**

1. Confirm the **retention rule**: "as long as needed for the claim" is ambiguous, and it's a
   legal question for an insurer. Until we get a straight answer I've kept originals forever
   and only auto-expire unprocessed uploads that sit in `staging/` for 90 days. If legal says
   e.g. "7 years after claim closure", I'll add a proper expiration rule — but someone needs
   to tell us the number.
2. **Object naming convention** from the app side (I'm assuming `<claim-id>/<doc-type>/<uuid>.<ext>`;
   adjust if the app does something different, since lifecycle and OCR may key off it).
3. Whether the **backend upload happens in-cluster** or externally — determines whether we use
   the IRSA role I built or need a federated/temp-creds path for external uploads.

If you give me 1–2 by EOD, dev is fully usable for your testing this week and I'll sequence
the prod cutover around the flow launch.

Cheers,
Renald

---

## Notes to myself (not part of the reply)

- Buckets: `live/.../claims/{dev,prod}/claim-documents-bucket` (module `s3-bucket`, versioning on, lifecycle only for `staging/`).
- Upload roles: `live/.../claims/{dev,prod}/claim-documents-uploader` — EKS service account `claim-documents-uploader`, `s3:PutObject` only. Prod role exists but we apply it when the flow ships to prod (already coded).
- Worker read access: added `ReadClaimDocuments` statement to both `claims-worker-iam` stacks; `DOCUMENTS_BUCKET` in dev+prod values.
- What I did NOT build: human IAM user with long-lived keys (see reply), KMS CMK on the buckets, bucket policies beyond IAM. Both are deliberate deferrals — flag in task 01 risk list, not this week.
