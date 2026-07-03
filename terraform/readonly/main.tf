# =============================================================================
# CLOUDPI READ-ONLY IAM ROLE (ORG LEVEL)
# =============================================================================

data "aws_partition" "current" {}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${var.trusted_account_id}:root"]
    }

    dynamic "condition" {
      for_each = var.external_id != "" ? [var.external_id] : []
      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [condition.value]
      }
    }
  }
}

resource "aws_iam_role" "cloudpi" {
  name               = var.role_name
  description        = var.role_description
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = var.tags
}

locals {
  cur_bucket_resources = length(var.cur_bucket_arns) > 0 ? var.cur_bucket_arns : ["*"]
}

resource "aws_iam_policy" "cloudpi" {
  name        = "${var.role_name}-policy"
  description = "CloudPi read-only permissions for billing, inventory, and monitoring"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "BillingRead",
        Effect = "Allow",
        Action = [
          "aws-portal:ViewBilling",
          "aws-portal:ViewUsage",
          "billing:Get*",
          "budgets:ViewBudget",
          "pricing:GetProducts",
          # ce/cur restricted to the exact actions CloudPi uses (matches live policy)
          "ce:GetCostAndUsage",
          "ce:GetCostAndUsageWithResources",
          "ce:GetCostForecast",
          "ce:GetDimensionValues",
          "ce:GetTags",
          "cur:DescribeReportDefinitions"
        ],
        Resource = "*"
      },
      {
        Sid    = "OrgRead",
        Effect = "Allow",
        Action = [
          "organizations:Describe*",
          "organizations:List*",
          "account:ListRegions",
          "account:GetRegionOptStatus"
        ],
        Resource = "*"
      },
      {
        Sid    = "InventoryRead",
        Effect = "Allow",
        Action = [
          "ec2:Describe*",
          "rds:Describe*",
          "elasticache:Describe*",
          "lambda:List*",
          "lambda:Get*",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "cloudwatch:Describe*",
          "logs:Describe*",
          "tag:GetResources",
          "resourcegroupstaggingapi:GetResources"
        ],
        Resource = "*"
      },
      {
        Sid    = "CurS3Read",
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Resource = local.cur_bucket_resources
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cloudpi" {
  role       = aws_iam_role.cloudpi.name
  policy_arn = aws_iam_policy.cloudpi.arn
}

# IAM user + access keys (optional direct access)
resource "aws_iam_user" "cloudpi" {
  name = var.user_name
  tags = var.tags
}

resource "aws_iam_user_policy_attachment" "cloudpi" {
  user       = aws_iam_user.cloudpi.name
  policy_arn = aws_iam_policy.cloudpi.arn
}

resource "aws_iam_access_key" "cloudpi" {
  user = aws_iam_user.cloudpi.name
}
