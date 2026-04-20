locals {
  enabled = module.this.enabled
}

data "tls_certificate" "github" {
  count = local.enabled ? 1 : 0

  url = "https://${var.github_oidc_host}"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.enabled ? 1 : 0

  url             = "https://${var.github_oidc_host}"
  client_id_list  = var.client_id_list
  thumbprint_list = coalescelist(var.thumbprint_list, [data.tls_certificate.github[0].certificates[0].sha1_fingerprint])

  tags = module.this.tags
}
