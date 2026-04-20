output "managed_rule_names" {
  description = "CIS managed rule names."
  value       = try(module.cis_rules.managed_rule_names, [])
}
