output "conformance_pack_name" {
  description = "Pack name."
  value       = try(module.pack.name, null)
}

output "conformance_pack_arn" {
  description = "Pack ARN."
  value       = try(module.pack.arn, null)
}
