output "zone_id" {
  description = "Primary zone ID."
  value       = try(aws_route53_zone.primary[0].zone_id, null)
}

output "name_servers" {
  description = "Primary zone nameservers — used as NS values by dns-delegated children."
  value       = try(aws_route53_zone.primary[0].name_servers, [])
}

output "zone_name" {
  description = "Zone name (echo)."
  value       = var.zone_name
}
