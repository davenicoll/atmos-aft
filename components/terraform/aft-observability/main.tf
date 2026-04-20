locals {
  enabled = module.this.enabled
}

resource "aws_cloudwatch_query_definition" "saved" {
  for_each = local.enabled ? var.queries : {}

  name            = "${module.this.id}/${each.key}"
  log_group_names = each.value.log_group_names
  query_string    = each.value.query_string
}
