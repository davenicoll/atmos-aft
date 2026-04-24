locals {
  enabled = module.this.enabled
}

# AWS stopped validating the thumbprint for token.actions.githubusercontent.com
# in mid-2023 (the IdP moved behind an AWS-managed trust store) but the
# CreateOpenIDConnectProvider API still rejects an empty thumbprint_list. We
# therefore pin the two well-known GitHub Actions OIDC thumbprints via the
# var.thumbprint_list default rather than fetching them at plan time through
# a tls data source - that data source makes the plan non-idempotent when
# GitHub rotates certificates and adds a runtime dependency on outbound egress
# from whatever workspace runs terraform plan.
resource "aws_iam_openid_connect_provider" "github" {
  count = local.enabled ? 1 : 0

  url             = "https://${var.github_oidc_host}"
  client_id_list  = var.client_id_list
  thumbprint_list = var.thumbprint_list

  tags = module.this.tags
}
