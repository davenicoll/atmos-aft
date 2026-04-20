output "budget_names" {
  description = "Budget names."
  value       = try(module.budgets.budget_names, [])
}

output "budget_ids" {
  description = "Budget IDs."
  value       = try(module.budgets.budget_ids, [])
}
