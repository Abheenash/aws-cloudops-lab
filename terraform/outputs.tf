output "app_url" {
  description = "Public URL of the app (through the ALB)"
  value       = "http://${aws_lb.app.dns_name}"
}

output "alb_dns_name" {
  value = aws_lb.app.dns_name
}

output "asg_name" {
  description = "Auto Scaling Group name (used by the incident drills)"
  value       = aws_autoscaling_group.app.name
}

output "db_identifier" {
  description = "RDS instance identifier (used by the restore-test drill)"
  value       = aws_db_instance.main.identifier
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.golden.dashboard_name}"
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
