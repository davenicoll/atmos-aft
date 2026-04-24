output "conformance_pack_name" {
  description = "Pack name. Null when skip_on_ct_managed_account=true."
  value       = try(module.pack[0].name, null)
}

output "conformance_pack_arn" {
  description = "Pack ARN. Null when skip_on_ct_managed_account=true."
  value       = try(module.pack[0].arn, null)
}
