output "deployment_role_arn" {
  description = "ARN of AtmosDeploymentRole in the target account. Consumed by the Atmos auth chain's `target` provider alias."
  value       = try(aws_iam_role.deployment[0].arn, null)
}

output "readonly_role_arn" {
  description = "ARN of AtmosDeploymentRole-ReadOnly in the target account. Consumed by pr.yaml via the Atmos auth chain's read-only provider alias."
  value       = try(aws_iam_role.readonly[0].arn, null)
}

output "account_class" {
  description = "Echoed back for downstream consumers that branch on class."
  value       = var.account_class
}

output "external_id_required" {
  description = "Whether this placement enforces sts:ExternalId. True on CT-core (ct-mgmt/aft-mgmt/audit/log-archive), false on vended."
  value       = contains(["ct-mgmt", "aft-mgmt", "audit", "log-archive"], var.account_class)
}
