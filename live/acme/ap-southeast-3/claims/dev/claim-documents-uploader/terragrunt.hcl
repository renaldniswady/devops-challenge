include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "${get_repo_root()}/modules//irsa-role"
}

dependency "eks" {
  config_path = "../../../platform/dev/eks"

  mock_outputs = {
    oidc_provider_arn = "arn:aws:iam::111111111111:oidc-provider/oidc.eks.ap-southeast-3.amazonaws.com/id/MOCK"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "bucket" {
  config_path = "../claim-documents-bucket"

  mock_outputs = {
    bucket_arn = "arn:aws:s3:::acme-claim-documents-dev"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Role used by the backend (and laptop scripts) to upload claim documents.
# It is an EKS service account, not a human IAM user with access keys — see
# tasks/03-reply-to-rina.md for why that matters. Dev only, as requested; the
# prod equivalent comes when the flow ships to prod.
inputs = {
  name              = "claim-documents-uploader-dev"
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
