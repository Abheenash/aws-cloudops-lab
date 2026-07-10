# Account-wide security services, all gated behind var.enable_security_baseline.
# These are account-level and bill separately — see cost-analysis/.

data "aws_caller_identity" "current" {}

# --- GuardDuty -------------------------------------------------------------
resource "aws_guardduty_detector" "this" {
  count  = var.enable_security_baseline ? 1 : 0
  enable = true
}

# --- Security Hub ----------------------------------------------------------
resource "aws_securityhub_account" "this" {
  count = var.enable_security_baseline ? 1 : 0
}

# --- Inspector (v2) --------------------------------------------------------
resource "aws_inspector2_enabler" "this" {
  count          = var.enable_security_baseline ? 1 : 0
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["EC2", "ECR"]
}

# --- AWS Config ------------------------------------------------------------
resource "aws_s3_bucket" "config" {
  count         = var.enable_security_baseline ? 1 : 0
  bucket        = "${var.prefix}-config-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "config" {
  count                   = var.enable_security_baseline ? 1 : 0
  bucket                  = aws_s3_bucket.config[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "config_bucket" {
  count = var.enable_security_baseline ? 1 : 0
  statement {
    sid     = "AWSConfigWrite"
    actions = ["s3:PutObject"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    resources = ["${aws_s3_bucket.config[0].arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
  statement {
    sid       = "AWSConfigBucketAcl"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.config[0].arn]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_s3_bucket_policy" "config" {
  count  = var.enable_security_baseline ? 1 : 0
  bucket = aws_s3_bucket.config[0].id
  policy = data.aws_iam_policy_document.config_bucket[0].json
}

data "aws_iam_policy_document" "config_assume" {
  count = var.enable_security_baseline ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  count              = var.enable_security_baseline ? 1 : 0
  name               = "${var.prefix}-config-role"
  assume_role_policy = data.aws_iam_policy_document.config_assume[0].json
}

resource "aws_iam_role_policy_attachment" "config" {
  count      = var.enable_security_baseline ? 1 : 0
  role       = aws_iam_role.config[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_config_configuration_recorder" "this" {
  count    = var.enable_security_baseline ? 1 : 0
  name     = "${var.prefix}-recorder"
  role_arn = aws_iam_role.config[0].arn
  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "this" {
  count          = var.enable_security_baseline ? 1 : 0
  name           = "${var.prefix}-delivery"
  s3_bucket_name = aws_s3_bucket.config[0].bucket
  depends_on     = [aws_config_configuration_recorder.this]
}

resource "aws_config_configuration_recorder_status" "this" {
  count      = var.enable_security_baseline ? 1 : 0
  name       = aws_config_configuration_recorder.this[0].name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.this]
}
