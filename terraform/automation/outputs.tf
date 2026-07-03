output "role_arn" {
  description = "IAM Role ARN for CloudPi"
  value       = aws_iam_role.cloudpi.arn
}

output "external_id" {
  description = "External ID configured for AssumeRole"
  value       = var.external_id
}

output "access_key_id" {
  description = "IAM access key ID for CloudPi user"
  value       = aws_iam_access_key.cloudpi.id
}

output "secret_access_key" {
  description = "IAM secret access key for CloudPi user"
  value       = aws_iam_access_key.cloudpi.secret
  sensitive   = true
}
