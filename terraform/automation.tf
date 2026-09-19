# The non-prod scheduler as infrastructure, not a README snippet: the Lambda in
# automation/nonprod_scheduler.py, an execution role that can only touch this ASG,
# and two EventBridge Scheduler schedules (stop 20:00, start 08:00, weekdays,
# America/Chicago). Cost model: the two app instances run ~60 h/week instead of 168.

data "archive_file" "scheduler" {
  type        = "zip"
  source_file = "${path.module}/../automation/nonprod_scheduler.py"
  output_path = "${path.module}/build/nonprod_scheduler.zip"
}

data "aws_iam_policy_document" "scheduler_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler_lambda" {
  name               = "${var.prefix}-nonprod-scheduler-role"
  assume_role_policy = data.aws_iam_policy_document.scheduler_lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "scheduler_logs" {
  role       = aws_iam_role.scheduler_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "scheduler_lambda" {
  statement {
    actions   = ["autoscaling:UpdateAutoScalingGroup"]
    resources = [aws_autoscaling_group.app.arn]
  }
  statement {
    actions   = ["autoscaling:DescribeAutoScalingGroups"]
    resources = ["*"] # Describe* does not support resource-level permissions
  }
}

resource "aws_iam_role_policy" "scheduler_lambda" {
  name   = "update-this-asg-only"
  role   = aws_iam_role.scheduler_lambda.id
  policy = data.aws_iam_policy_document.scheduler_lambda.json
}

resource "aws_lambda_function" "scheduler" {
  function_name    = "${var.prefix}-nonprod-scheduler"
  role             = aws_iam_role.scheduler_lambda.arn
  runtime          = "python3.12"
  handler          = "nonprod_scheduler.handler"
  filename         = data.archive_file.scheduler.output_path
  source_code_hash = data.archive_file.scheduler.output_base64sha256
  timeout          = 30
  environment {
    variables = {
      ASG_NAME       = aws_autoscaling_group.app.name
      START_CAPACITY = tostring(var.asg_desired)
    }
  }
  tracing_config {
    mode = "Active"
  }
}

resource "aws_cloudwatch_log_group" "scheduler" {
  name              = "/aws/lambda/${aws_lambda_function.scheduler.function_name}"
  retention_in_days = 30
}

# A failed stop/start must page: the scheduler raises on any AWS error.
resource "aws_cloudwatch_metric_alarm" "scheduler_errors" {
  alarm_name          = "${var.prefix}-nonprod-scheduler-errors"
  alarm_description   = "The non-prod scheduler failed — capacity may not have changed as scheduled"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.scheduler.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler_invoke" {
  name               = "${var.prefix}-scheduler-invoke-role"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "scheduler_invoke" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.scheduler.arn]
  }
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  name   = "invoke-nonprod-scheduler"
  role   = aws_iam_role.scheduler_invoke.id
  policy = data.aws_iam_policy_document.scheduler_invoke.json
}

resource "aws_scheduler_schedule" "stop" {
  name                         = "${var.prefix}-nonprod-stop"
  schedule_expression          = "cron(0 20 ? * MON-FRI *)"
  schedule_expression_timezone = var.schedule_timezone
  flexible_time_window {
    mode = "OFF"
  }
  target {
    arn      = aws_lambda_function.scheduler.arn
    role_arn = aws_iam_role.scheduler_invoke.arn
    input    = jsonencode({ action = "stop" })
    retry_policy {
      maximum_retry_attempts = 2
    }
  }
}

resource "aws_scheduler_schedule" "start" {
  name                         = "${var.prefix}-nonprod-start"
  schedule_expression          = "cron(0 8 ? * MON-FRI *)"
  schedule_expression_timezone = var.schedule_timezone
  flexible_time_window {
    mode = "OFF"
  }
  target {
    arn      = aws_lambda_function.scheduler.arn
    role_arn = aws_iam_role.scheduler_invoke.arn
    input    = jsonencode({ action = "start" })
    retry_policy {
      maximum_retry_attempts = 2
    }
  }
}
