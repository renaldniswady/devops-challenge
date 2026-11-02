include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "${get_repo_root()}/modules//irsa-role"
}

dependency "eks" {
  config_path = "../../../platform/prod/eks"

  mock_outputs = {
    oidc_provider_arn = "arn:aws:iam::111111111111:oidc-provider/oidc.eks.ap-southeast-3.amazonaws.com/id/MOCK"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "bucket" {
  config_path = "../claim-documents-bucket"

  mock_outputs = {
    bucket_arn = "arn:aws:s3:::acme-claim-documents-prod"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Prod upload role. Same shape as the dev one; applied when the redesigned flow
# reaches prod (Rina asked for dev first, and we shouldn't hand out prod upload
# permissions a week before the flow ships). See tasks/03-reply-to-rina.md.
inputs = {
  name              = "claim-documents-uploader-prod"
  oidc_provider_arn = dependency.eks.outputs.oidc_provider_arn
  namespace         = "claims"
  service_account   = "claim-documents-uploader"

  policy_statements = [
    {
      sid       = "UploadClaimDocuments"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = ["${dependency.bucket.outputs.bucket_arn}/*"]
    },
  ]
}
