# Per gha-design.md §10.1 the two auth modes use distinct secret shapes.
# Mode A (app): pem + installation-token (two secrets, distinct CMKs).
# Mode B (pat): one secret.

locals {
  app_mode = var.github_auth_mode == "app"
  pat_mode = var.github_auth_mode == "pat"
}

# ---------------------------------------------------------------------------
# Mode A: PEM source-of-truth + short-lived installation token
# ---------------------------------------------------------------------------

resource "aws_kms_key" "pem_secret" {
  count = local.enabled && local.app_mode ? 1 : 0

  description             = "CMK for the GitHub App private key secret. Rotator Lambda has Decrypt only; no grant to Encrypt."
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = module.this.tags
}

resource "aws_kms_alias" "pem_secret" {
  count         = local.enabled && local.app_mode ? 1 : 0
  name          = "alias/${module.this.id}-ct-dispatch-pem"
  target_key_id = aws_kms_key.pem_secret[0].id
}

resource "aws_secretsmanager_secret" "github_app_private_key" {
  count = local.enabled && local.app_mode ? 1 : 0

  name        = local.app_pem_secret_name
  description = "GitHub App private key (PEM). Long-lived source-of-truth; rotator Lambda decrypts it to mint installation tokens every 30 min. Manual rotation annually per org policy."
  kms_key_id  = aws_kms_key.pem_secret[0].arn

  tags = module.this.tags

  lifecycle {
    # The PEM is seeded out-of-band (one-shot console or CLI write by an
    # operator during App setup). Terraform owns the secret resource but not
    # the value; prevent an accidental rotation from bricking inbound.
    ignore_changes = [description]
  }
}

resource "aws_kms_key" "token_secret" {
  count = local.enabled && local.app_mode ? 1 : 0

  description             = "CMK for the installation-token secret. Rotator Lambda has Encrypt+GenerateDataKey only (to write tokens). EventBridge connection role has Decrypt only (to read)."
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = module.this.tags
}

resource "aws_kms_alias" "token_secret" {
  count         = local.enabled && local.app_mode ? 1 : 0
  name          = "alias/${module.this.id}-ct-dispatch-token"
  target_key_id = aws_kms_key.token_secret[0].id
}

resource "aws_secretsmanager_secret" "github_installation_token" {
  count = local.enabled && local.app_mode ? 1 : 0

  name        = local.app_token_secret_name
  description = "Short-lived (~1h) GitHub App installation token. Rotated every 30 min by the bespoke rotator Lambda. Read by the EventBridge connection."
  kms_key_id  = aws_kms_key.token_secret[0].arn

  tags = module.this.tags
}

# ---------------------------------------------------------------------------
# Mode B: fine-grained PAT (fallback)
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "github_pat" {
  count = local.enabled && local.pat_mode ? 1 : 0

  name        = local.pat_secret_name
  description = "Fine-grained GitHub PAT with Actions:write on ${var.github_org}/${var.github_repo}. Manual rotation every 90 days (operator toil — prefer mode=app)."

  tags = module.this.tags

  lifecycle {
    ignore_changes = [description]
  }
}
