output "ipam_id" {
  description = "IPAM ID."
  value       = try(aws_vpc_ipam.this[0].id, null)
}

output "ipam_arn" {
  description = "IPAM ARN."
  value       = try(aws_vpc_ipam.this[0].arn, null)
}

output "private_scope_id" {
  description = "Private scope ID (workload CIDRs)."
  value       = try(aws_vpc_ipam.this[0].private_default_scope_id, null)
}

output "top_pool_id" {
  description = "Top-level IPv4 pool ID."
  value       = try(aws_vpc_ipam_pool.top[0].id, null)
}
