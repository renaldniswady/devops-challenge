resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = var.tags
}

resource "aws_sqs_queue" "this" {
  name                       = var.name
  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = var.tags
}

# Notification channel for the alarm. The alarm below used to have no target at all,
# which is why the queue backlog went unnoticed until customers called — see
# incident/2026-10-14-claims-worker-crashloop/postmortem.md. Subscribe Slack / on-call here.
resource "aws_sns_topic" "alarm_notifications" {
  name_prefix = "${var.name}-alarms"
  tags        = var.tags
}

resource "aws_cloudwatch_metric_alarm" "oldest_message_age" {
  alarm_name        = "${var.name}-oldest-message-age"
  alarm_description = "Messages in ${var.name} are not being consumed"

  namespace   = "AWS/SQS"
  metric_name = "ApproximateAgeOfOldestMessage"
  dimensions = {
    QueueName = aws_sqs_queue.this.name
  }

  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.alarm_age_threshold_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = var.tags
}
