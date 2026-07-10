# Guardrail: a monthly cost budget that pages at 80% actual and 100% forecast.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.prefix}-monthly"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Notifications need a subscriber, so they exist only when alarm_email is set.
  # With no email the budget still tracks spend in the console (just no alerts).
  dynamic "notification" {
    for_each = var.alarm_email == "" ? [] : [1]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 80
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alarm_email]
    }
  }

  dynamic "notification" {
    for_each = var.alarm_email == "" ? [] : [1]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 100
      threshold_type             = "PERCENTAGE"
      notification_type          = "FORECASTED"
      subscriber_email_addresses = [var.alarm_email]
    }
  }
}
