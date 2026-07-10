resource "aws_cloudwatch_log_group" "app" {
  name              = "/cops/app"
  retention_in_days = 30
  tags              = { Name = "${var.prefix}-app-logs" }
}

# --- alerting channel ------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "${var.prefix}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# --- alarms: customer-facing symptoms -------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.prefix}-alb-5xx"
  alarm_description   = "Target 5xx responses — availability SLO at risk. Runbook: runbooks/elevated-5xx.md"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "alb_latency_p95" {
  alarm_name          = "${var.prefix}-alb-latency-p95"
  alarm_description   = "p95 target latency over 1.5s — latency SLO at risk. Runbook: runbooks/high-latency.md"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1.5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# --- alarms: causes --------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${var.prefix}-unhealthy-targets"
  alarm_description   = "One or more targets failing health checks. Runbook: runbooks/unhealthy-targets.md"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.prefix}-rds-cpu"
  alarm_description   = "RDS CPU sustained high. Runbook: runbooks/rds-pressure.md"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.prefix}-rds-connections"
  alarm_description   = "RDS connection count near capacity. Runbook: runbooks/rds-pressure.md"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# --- composite: one "is the service healthy?" page ------------------------
resource "aws_cloudwatch_composite_alarm" "service_health" {
  alarm_name        = "${var.prefix}-service-health"
  alarm_description = "Composite service health — fires if any symptom or cause alarm trips. Start at the dashboard, then the runbook named in the tripped child alarm."
  alarm_rule = join(" OR ", [
    "ALARM(${aws_cloudwatch_metric_alarm.alb_5xx.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.alb_latency_p95.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.unhealthy_hosts.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.rds_cpu.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.rds_connections.alarm_name})",
  ])
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# --- golden-signals dashboard ---------------------------------------------
resource "aws_cloudwatch_dashboard" "golden" {
  dashboard_name = "${var.prefix}-golden-signals"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6,
        properties = {
          title   = "Traffic — request count",
          region  = var.region,
          view    = "timeSeries",
          metrics = [["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.app.arn_suffix, { stat = "Sum" }]]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6,
        properties = {
          title   = "Errors — target 5xx",
          region  = var.region,
          view    = "timeSeries",
          metrics = [["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.app.arn_suffix, { stat = "Sum" }]]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6,
        properties = {
          title  = "Latency — target response time p50/p95",
          region = var.region,
          view   = "timeSeries",
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.app.arn_suffix, { stat = "p50", label = "p50" }],
            ["...", { stat = "p95", label = "p95" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6,
        properties = {
          title  = "Saturation — healthy vs unhealthy targets",
          region = var.region,
          view   = "timeSeries",
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.app.arn_suffix, "LoadBalancer", aws_lb.app.arn_suffix, { stat = "Average" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", aws_lb_target_group.app.arn_suffix, "LoadBalancer", aws_lb.app.arn_suffix, { stat = "Average" }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6,
        properties = {
          title   = "RDS CPU",
          region  = var.region,
          view    = "timeSeries",
          metrics = [["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.main.identifier, { stat = "Average" }]]
        }
      },
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6,
        properties = {
          title   = "RDS connections",
          region  = var.region,
          view    = "timeSeries",
          metrics = [["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.main.identifier, { stat = "Maximum" }]]
        }
      }
    ]
  })
}

# --- saved Logs Insights queries ------------------------------------------
resource "aws_cloudwatch_query_definition" "app_5xx" {
  name            = "cops/app-5xx-responses"
  log_group_names = [aws_cloudwatch_log_group.app.name]
  query_string    = <<-EOQ
    fields @timestamp, @message
    | filter @message like / 500 / or @message like / 503 /
    | sort @timestamp desc
    | limit 100
  EOQ
}

resource "aws_cloudwatch_query_definition" "app_errors" {
  name            = "cops/app-error-log"
  log_group_names = [aws_cloudwatch_log_group.app.name]
  query_string    = <<-EOQ
    fields @timestamp, @message
    | filter @logStream like /error/
    | sort @timestamp desc
    | limit 100
  EOQ
}

resource "aws_cloudwatch_query_definition" "rds_postgres" {
  name            = "cops/rds-postgres-log"
  log_group_names = ["/aws/rds/instance/${aws_db_instance.main.identifier}/postgresql"]
  query_string    = <<-EOQ
    fields @timestamp, @message
    | filter @message like /ERROR/ or @message like /FATAL/ or @message like /too many/
    | sort @timestamp desc
    | limit 100
  EOQ
}
