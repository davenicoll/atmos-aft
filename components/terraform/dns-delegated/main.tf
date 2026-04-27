locals {
  enabled = module.this.enabled
  fqdn    = "${var.subzone_label}.${var.parent_zone_name}"
}

resource "aws_route53_zone" "delegated" {
  count = local.enabled ? 1 : 0

  name          = local.fqdn
  comment       = "Delegated subzone for ${var.subzone_label}"
  force_destroy = false

  tags = module.this.tags
}

# Delegation NS record in the parent zone - only rendered when parent_zone_id is provided
# (i.e. when the component can write to the parent zone). Cross-account setups omit
# parent_zone_id and create the delegation record externally.
resource "aws_route53_record" "delegation" {
  count = local.enabled && var.parent_zone_id != null ? 1 : 0

  zone_id = var.parent_zone_id
  name    = local.fqdn
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.delegated[0].name_servers
}
