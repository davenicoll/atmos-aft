output "zone_id" {
  description = "Delegated zone ID."
  value       = try(aws_route53_zone.delegated[0].zone_id, null)
}

output "zone_name" {
  description = "Delegated zone FQDN."
  value       = try(aws_route53_zone.delegated[0].name, null)
}

output "name_servers" {
  description = "Delegated zone nameservers."
  value       = try(aws_route53_zone.delegated[0].name_servers, [])
}
