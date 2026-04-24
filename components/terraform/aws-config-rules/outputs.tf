output "managed_rule_names" {
  description = "CIS managed rule names. Empty when skip_on_ct_managed_account=true."
  value       = try(module.cis_rules[0].managed_rule_names, [])
}
