locals {
  enabled = module.this.enabled
}

resource "aws_vpc_ipam" "this" {
  count = local.enabled ? 1 : 0

  description = var.description

  dynamic "operating_regions" {
    for_each = var.operating_regions
    content {
      region_name = operating_regions.value
    }
  }

  tags = module.this.tags
}

resource "aws_vpc_ipam_scope" "private" {
  count = local.enabled ? 1 : 0

  ipam_id     = aws_vpc_ipam.this[0].id
  description = "Private scope for workload CIDRs."
  tags        = module.this.tags
}

resource "aws_vpc_ipam_pool" "top" {
  count = local.enabled ? 1 : 0

  address_family = "ipv4"
  ipam_scope_id  = aws_vpc_ipam.this[0].private_default_scope_id
  locale         = var.region
  description    = "Top-level IPv4 pool."
  tags           = module.this.tags
}

resource "aws_vpc_ipam_pool_cidr" "top" {
  count = local.enabled ? 1 : 0

  ipam_pool_id = aws_vpc_ipam_pool.top[0].id
  cidr         = var.top_pool_cidr
}
