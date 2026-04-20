output "account_id" {
  description = "12-digit AWS account ID of the newly vended account. Extracted from the provisioned product's RecordOutputs.AccountId. Published to SSM at /aft/account/<name>/id via the store-outputs hook."
  value       = local.account_id
}

output "account_name" {
  description = "Echo of the input account name."
  value       = var.account_name
}

output "account_email" {
  description = "Echo of the root email (for audit-trail consumption)."
  value       = var.account_email
  sensitive   = true
}

output "managed_organizational_unit" {
  description = "Echo of the OU placement."
  value       = var.managed_organizational_unit
}

output "provisioned_product_id" {
  description = "Service Catalog provisioned-product ID. Used by destroy-account.yaml to call TerminateProvisionedProduct."
  value       = try(aws_servicecatalog_provisioned_product.account[0].id, null)
}

output "provisioned_product_arn" {
  description = "Provisioned-product ARN."
  value       = try(aws_servicecatalog_provisioned_product.account[0].arn, null)
}

output "status" {
  description = "Provisioning status at last apply. Published to /aft/account/<name>/status as the runtime state row (replaces aft-request-metadata DDB table — mapping.md §4.1)."
  value       = try(aws_servicecatalog_provisioned_product.account[0].status, null)
}
