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

dependency "queue" {
  config_path = "../claims-documents-queue"

  mock_outputs = {
    queue_arn = "arn:aws:sqs:ap-southeast-3:111111111111:claims-documents"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "documents" {
  config_path = "../claim-documents-bucket"

  mock_outputs = {
    bucket_arn = "arn:aws:s3:::acme-claim-documents-prod"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  name              = "claims-worker-prod"
  oidc_provider_arn = dependency.eks.outputs.oidc_provider_arn
  namespace         = "claims"
  # The pods run as this service account (see apps/acme-prod-cluster/values/claims-worker.yaml);
  # the OIDC sub claim must match exactly or STS rejects the token.
  service_account   = "claims-worker-sa"

  policy_statements = [
    # TODO: tighten to the claims-documents queue + dlq (match the dev stack).
    {
      sid       = "Queue"
      effect    = "Allow"
      actions   = ["sqs:*"]
      resources = ["*"]
    },
    # OCR reads the uploaded documents. Read-only, no writes or deletes.
    {
      sid       = "ReadClaimDocuments"
      effect    = "Allow"
      actions   = ["s3:GetObject", "s3:ListBucket"]
      resources = [dependency.documents.outputs.bucket_arn, "${dependency.documents.outputs.bucket_arn}/*"]
    },
  ]
}
