# =============================================================================
# AUTH / TRUST VARIABLES
# =============================================================================

variable "aws_region" {
  description = "AWS region for provider operations"
  type        = string
  default     = "us-east-1"
}

variable "trusted_account_id" {
  description = "CloudPi AWS account ID allowed to assume the role"
  type        = string
}

variable "external_id" {
  description = "External ID required for AssumeRole (recommended)"
  type        = string
  default     = ""
}

# =============================================================================
# ROLE CONFIGURATION
# =============================================================================

variable "role_name" {
  description = "IAM role name for CloudPi access"
  type        = string
  default     = "cloudpi-readonly-role"
}

variable "role_description" {
  description = "Description for the IAM role"
  type        = string
  default     = "CloudPi read-only access for billing, inventory, and monitoring"
}

variable "user_name" {
  description = "IAM user name for CloudPi (access key/secret)"
  type        = string
  default     = "cloudpi-readonly-user"
}

variable "tags" {
  description = "Tags to apply to IAM resources"
  type        = map(string)
  default = {
    ManagedBy   = "Terraform"
    Purpose     = "CloudPi-ReadOnly"
    Application = "CloudPi"
  }
}

# Optional: restrict CUR bucket access (leave empty for all buckets)
variable "cur_bucket_arns" {
  description = "List of S3 bucket ARNs that store CUR exports"
  type        = list(string)
  default     = []
}
