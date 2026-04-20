locals {
  enabled = module.this.enabled
}

resource "aws_route53_zone" "primary" {
  count = local.enabled ? 1 : 0

  name          = var.zone_name
  comment       = var.comment
  force_destroy = false

  tags = module.this.tags
}
