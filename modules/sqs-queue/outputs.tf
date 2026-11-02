output "queue_name" {
  value = aws_sqs_queue.this.name
}

output "queue_url" {
  value = aws_sqs_queue.this.url
}

output "queue_arn" {
  value = aws_sqs_queue.this.arn
}

output "dlq_arn" {
  value = aws_sqs_queue.dlq.arn
}

# Point subscribers/on-call at this so alarm state changes actually get delivered.
output "alarm_topic_arn" {
  description = "SNS topic the oldest-message alarm sends to."
  value       = aws_sns_topic.alarm_notifications.arn
}
