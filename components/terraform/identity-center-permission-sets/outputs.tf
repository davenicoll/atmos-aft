output "permission_set_arns" {
  description = "Map of permission-set name → ARN."
  value       = { for k, v in module.permission_sets.permission_sets : k => v.arn }
}
