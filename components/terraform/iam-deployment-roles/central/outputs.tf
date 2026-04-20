output "central_role_arn" {
  description = "ARN of AtmosCentralDeploymentRole. Consumed by every workflow's OIDC configure-credentials step."
  value       = try(aws_iam_role.central[0].arn, null)
}

output "central_role_name" {
  value = try(aws_iam_role.central[0].name, null)
}

output "plan_only_role_arn" {
  description = "ARN of AtmosPlanOnlyRole. Consumed by pr.yaml."
  value       = try(aws_iam_role.plan_only[0].arn, null)
}

output "read_all_state_role_arn" {
  description = "ARN of AtmosReadAllStateRole. Consumed by drift-summary aggregation; also referenced by every target-account KMS key policy and S3 bucket policy for cross-account reads."
  value       = try(aws_iam_role.read_all_state[0].arn, null)
}
