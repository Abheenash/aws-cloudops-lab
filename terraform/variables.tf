variable "region" {
  description = "AWS region for the lab"
  type        = string
  default     = "us-east-1"
}

variable "prefix" {
  description = "Name prefix applied to every resource"
  type        = string
  default     = "cops"
}

variable "vpc_cidr" {
  description = "CIDR block for the lab VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "instance_type" {
  description = "EC2 instance type for the app tier"
  type        = string
  default     = "t3.micro"
}

variable "asg_desired" {
  description = "Desired number of app instances"
  type        = number
  default     = 2
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "copsdb"
}

variable "alarm_email" {
  description = "Email to subscribe to the alerts SNS topic. Leave blank to skip the subscription."
  type        = string
  default     = ""
}

variable "budget_limit_usd" {
  description = "Monthly cost budget in USD (string, per AWS Budgets API)"
  type        = string
  default     = "20"
}

variable "enable_security_baseline" {
  description = "Enable the ACCOUNT-WIDE security services (GuardDuty, Security Hub, Inspector, AWS Config). Off by default because these are account-level and bill separately — turn on deliberately for the security-findings drill."
  type        = bool
  default     = false
}
