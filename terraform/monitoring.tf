# =========================================================
# CloudWatch alarms -> SNS notifications (AWS infrastructure monitoring)
# Application/container logs go to the ELK stack (see README "Logging").
# Standard EC2/RDS metrics are free; each alarm costs ~$0.10/month.
# =========================================================

resource "aws_sns_topic" "alerts" {
  name              = "${var.project_name}-alerts"
  kms_master_key_id = aws_kms_key.app.id

  tags = {
    Name = "${var.project_name}-alerts"
  }
}

# Who may publish: CloudWatch alarms and AWS Budgets from this account
resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountOwner"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = ["SNS:Publish", "SNS:Subscribe", "SNS:GetTopicAttributes", "SNS:SetTopicAttributes", "SNS:ListSubscriptionsByTopic"]
        Resource  = aws_sns_topic.alerts.arn
      },
      {
        Sid       = "AlarmAndBudgetPublishers"
        Effect    = "Allow"
        Principal = { Service = ["cloudwatch.amazonaws.com", "budgets.amazonaws.com"] }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
      }
    ]
  })
}

# Audit/verification queue: every alert is also delivered here (retained 4 days), so delivery can
# be proven without a mailbox and alert history can be inspected with the CLI.
resource "aws_sqs_queue" "alerts_audit" {
  count                     = var.create_alert_audit_queue ? 1 : 0
  name                      = "${var.project_name}-alerts-audit"
  message_retention_seconds = 345600
  kms_master_key_id         = aws_kms_key.app.id
}

resource "aws_sqs_queue_policy" "alerts_audit" {
  count     = var.create_alert_audit_queue ? 1 : 0
  queue_url = aws_sqs_queue.alerts_audit[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.alerts_audit[0].arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.alerts.arn } }
    }]
  })
}

resource "aws_sns_topic_subscription" "alerts_audit" {
  count                = var.create_alert_audit_queue ? 1 : 0
  topic_arn            = aws_sns_topic.alerts.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.alerts_audit[0].arn
  raw_message_delivery = false
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  alarm_actions = [aws_sns_topic.alerts.arn]
}

# ---------------- RDS ----------------

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${var.project_name}-rds-cpu-high"
  alarm_description   = "RDS CPU above 80% for 10 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.mysql.identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  alarm_name          = "${var.project_name}-rds-free-storage-low"
  alarm_description   = "RDS free storage below 2 GiB"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.mysql.identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2 * 1024 * 1024 * 1024
  comparison_operator = "LessThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "rds_freeable_memory_low" {
  alarm_name = "${var.project_name}-rds-freeable-memory-low"
  # Calibrated on the deployed db.t3.micro: RDS's own OS/agents leave a steady 40-60 MiB free even
  # with no connections (observed 2026-10-18/19), so 64 MiB fired permanently. 25 MiB = exhaustion.
  alarm_description   = "RDS freeable memory below 25 MiB for 10 minutes (memory exhaustion)"
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.mysql.identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 25 * 1024 * 1024
  comparison_operator = "LessThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# Sustained swapping is the meaningful memory-pressure signal on small instance classes
resource "aws_cloudwatch_metric_alarm" "rds_swap_high" {
  alarm_name          = "${var.project_name}-rds-swap-high"
  alarm_description   = "RDS swap usage above 200 MiB for 15 minutes (instance under memory pressure)"
  namespace           = "AWS/RDS"
  metric_name         = "SwapUsage"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.mysql.identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 200 * 1024 * 1024
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  alarm_name          = "${var.project_name}-rds-connections-high"
  alarm_description   = "RDS connections above 50 (backend pool is 10 per pod)"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.mysql.identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 50
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# ---------------- Jenkins EC2 ----------------

resource "aws_cloudwatch_metric_alarm" "jenkins_status_check" {
  count               = local.jenkins_count
  alarm_name          = "${var.project_name}-jenkins-status-check-failed"
  alarm_description   = "Jenkins EC2 instance or system status check failing"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = aws_instance.jenkins[0].id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "jenkins_cpu_high" {
  count               = local.jenkins_count
  alarm_name          = "${var.project_name}-jenkins-cpu-high"
  alarm_description   = "Jenkins CPU above 85% for 15 minutes"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = aws_instance.jenkins[0].id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# ---------------- EKS worker nodes ----------------

resource "aws_cloudwatch_metric_alarm" "eks_nodes_cpu_high" {
  alarm_name          = "${var.project_name}-eks-nodes-cpu-high"
  alarm_description   = "Average CPU across EKS worker nodes above 80% for 15 minutes (consider scaling the node group)"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { AutoScalingGroupName = aws_eks_node_group.main.resources[0].autoscaling_groups[0].name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# ---------------- NAT Gateway ----------------

resource "aws_cloudwatch_metric_alarm" "nat_port_allocation_errors" {
  alarm_name          = "${var.project_name}-nat-port-allocation-errors"
  alarm_description   = "NAT gateway could not allocate source ports (private subnet egress failing)"
  namespace           = "AWS/NATGateway"
  metric_name         = "ErrorPortAllocation"
  dimensions          = { NatGatewayId = aws_nat_gateway.nat.id }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

# The application ALB is created by the AWS Load Balancer Controller (not Terraform), so its
# 5xx / unhealthy-target alarms are created after deployment by scripts/create-alb-alarms.sh.

# ---------------- Log retention for RDS log exports ----------------
# RDS would create these groups with "never expire"; pre-creating them bounds cost.

resource "aws_cloudwatch_log_group" "rds" {
  for_each          = toset(["error", "slowquery"])
  name              = "/aws/rds/instance/${var.project_name}-mysql/${each.key}"
  retention_in_days = var.log_retention_days
}

# ---------------- Cost guardrail ----------------
# AWS Budgets: the first two action-free budgets per account are free.

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project_name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"

  depends_on = [aws_sns_topic_policy.alerts]
  time_unit  = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
    subscriber_email_addresses = var.alert_email == "" ? [] : [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
    subscriber_email_addresses = var.alert_email == "" ? [] : [var.alert_email]
  }
}
