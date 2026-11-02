include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "${get_repo_root()}/modules//sqs-queue"
}

inputs = {
  name                        = "claims-documents"
  visibility_timeout_seconds  = 300
  max_receive_count           = 5
  alarm_age_threshold_seconds = 900

  # Previously empty: the oldest-message alarm went to ALARM on 14 Oct and nobody was paged.
  # The topic below is created by the module with prefix <queue name>-alarms (see its test).
  alarm_actions = ["arn:aws:sns:ap-southeast-3:111111111111:claims-documents-alarms"]
}
