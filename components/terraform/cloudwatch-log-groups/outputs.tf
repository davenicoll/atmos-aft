output "log_group_names" {
  description = "Map of logical name → log-group name."
  value       = { for k, m in module.log_group : k => m.log_group_name }
}

output "log_group_arns" {
  description = "Map of logical name → log-group ARN."
  value       = { for k, m in module.log_group : k => m.log_group_arn }
}
