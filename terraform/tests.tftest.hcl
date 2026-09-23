mock_provider "aws" {
  # Mocked data sources return placeholder strings that the AWS provider then
  # rejects as invalid JSON; a minimal valid document keeps the mock usable.
  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["us-east-1a", "us-east-1b"] }
  }
  override_data {
    target = data.aws_iam_policy_document.config_assume
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.config_bucket
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.ec2_assume
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.read_db_secret
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.scheduler_assume
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.scheduler_invoke
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.scheduler_lambda
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.scheduler_lambda_assume
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
mock_provider "archive" {}
run "database_is_not_publicly_reachable" {
  command = plan

  assert {
    condition     = !aws_db_instance.main.publicly_accessible
    error_message = "The RDS instance must not be publicly accessible. It sits behind the app tier and nothing else should reach it."
  }

  assert {
    condition     = aws_db_instance.main.storage_encrypted
    error_message = "RDS storage must be encrypted at rest."
  }
}

run "instances_require_imdsv2" {
  command = plan

  # IMDSv1 is how a single SSRF in the app becomes stolen instance credentials.
  # This is the one EC2 setting that most often turns a small bug into an incident.
  assert {
    condition     = aws_launch_template.app.metadata_options[0].http_tokens == "required"
    error_message = "The launch template must require IMDSv2 (http_tokens = required). With IMDSv1 enabled, an SSRF in the app yields the instance role's credentials."
  }
}

run "every_alarm_points_at_a_runbook_that_exists" {
  command = plan

  # CI already greps the runbook filenames out of observability.tf and checks the
  # files exist. This asserts the other half: that the alarms actually carry a
  # description pointing somewhere, so the grep has something to find.
  assert {
    condition = alltrue([
      aws_cloudwatch_metric_alarm.alb_5xx.alarm_description != "",
      aws_cloudwatch_metric_alarm.alb_latency_p95.alarm_description != "",
      aws_cloudwatch_metric_alarm.unhealthy_hosts.alarm_description != "",
      aws_cloudwatch_metric_alarm.rds_cpu.alarm_description != "",
      aws_cloudwatch_metric_alarm.rds_connections.alarm_description != "",
    ])
    error_message = "Every alarm needs a description naming its runbook. An alarm that pages at 2am without one is a puzzle, not a signal."
  }
}
