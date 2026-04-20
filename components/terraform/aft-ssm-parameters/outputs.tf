output "parameter_arns" {
  description = "Map of parameter name → ARN."
  value       = try(module.parameters.names, {})
}

output "parameter_names" {
  description = "List of parameter names created."
  value       = try(keys(var.parameters), [])
}
