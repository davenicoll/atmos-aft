output "function_arns" {
  description = "Map of logical name → function ARN."
  value       = { for k, m in module.lambda : k => m.arn }
}

output "function_names" {
  description = "Map of logical name → function name."
  value       = { for k, m in module.lambda : k => m.function_name }
}

output "role_arns" {
  description = "Map of logical name → execution role ARN."
  value       = { for k, m in module.lambda : k => m.role_arn }
}
