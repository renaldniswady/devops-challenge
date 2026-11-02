include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "${get_repo_root()}/modules//s3-bucket"
}

# Prod counterpart of the dev claim-documents bucket. Same retention policy:
# originals are kept for the lifetime of the claim; only unprocessed uploads in
# staging/ expire after 90 days. See the dev stack for the reasoning.
inputs = {
  name       = "acme-claim-documents-prod"
  versioning = true

  lifecycle_rules = [
    {
      id              = "expire-unprocessed-staging"
      prefix          = "staging/"
      expiration_days = 90
    },
  ]
}
