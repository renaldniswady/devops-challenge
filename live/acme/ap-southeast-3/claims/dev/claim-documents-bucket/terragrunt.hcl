include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "${get_repo_root()}/modules//s3-bucket"
}

# Upload target for customer-submitted claim documents (KTP, receipts, medical
# documents). The claims-worker reads from here for OCR.
#
# "Keep as long as needed for the claim": we keep originals forever and only
# expire unprocessed uploads that are still sitting in the staging prefix after
# 90 days. If legal/claims later gives us a retention window, add an expiration
# rule for the root prefix then — do not delete on schedule in the meantime.
inputs = {
  name       = "acme-claim-documents-dev"
  versioning = true

  lifecycle_rules = [
    {
      id              = "expire-unprocessed-staging"
      prefix          = "staging/"
      expiration_days = 90
    },
  ]
}
