output "permission_set_arns" {
  description = "Map of permission-set name → ARN."
  value       = try(module.permission_sets.permission_sets, {})
}
