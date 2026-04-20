output "parameter_arns" {
  description = "Map of parameter name → ARN."
  value       = try(module.parameters.arn_map, {})
}

output "parameter_names" {
  description = "List of parameter names created."
  value       = try(keys(var.parameters), [])
}
