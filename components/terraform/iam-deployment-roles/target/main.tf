locals {
  enabled = module.this.enabled

  # ExternalId is required for the four CT-core placements (extra guardrail
  # given those accounts predate Atmos). Vended accounts skip it because the
  # fresh account ID itself is the uniqueness signal.
  ct_core_classes     = ["ct-mgmt", "aft-mgmt", "audit", "log-archive"]
  require_external_id = contains(local.ct_core_classes, var.account_class)

  central_role_arn = "arn:aws:iam::${var.aft_mgmt_account_id}:role/AtmosCentralDeploymentRole"
  plan_only_arn    = "arn:aws:iam::${var.aft_mgmt_account_id}:role/AtmosPlanOnlyRole"
}

# ---------------------------------------------------------------------------
# AtmosDeploymentRole - admin role assumed from central for every component apply.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deployment_trust" {
  provider = aws.target

  statement {
    sid     = "AllowAssumeFromCentral"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [local.central_role_arn]
    }

    dynamic "condition" {
      for_each = local.require_external_id ? [1] : []
      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [var.atmos_external_id]
      }
    }

    condition {
      test     = "StringLike"
      variable = "aws:userid"
      values = [
        "AROA*:atmos-aft",
        "AROA*:atmos-aft-bootstrap",
      ]
    }
  }
}

resource "aws_iam_role" "deployment" {
  provider = aws.target
  count    = local.enabled ? 1 : 0

  name                 = "AtmosDeploymentRole"
  description          = "Atmos last-hop deployment identity in ${var.account_class} account. Admin policy; restrictions enforced upstream at AtmosCentralDeploymentRole's assume-role resource list and at the OU SCP layer."
  assume_role_policy   = data.aws_iam_policy_document.deployment_trust.json
  max_session_duration = var.max_session_duration

  # Cross-variable guard: CT-core classes require a non-empty ExternalId. An
  # empty string would render `values = [""]` in the trust statement, which
  # is syntactically valid but locks the role out for everyone - silent
  # bricking. Variable validation can't reach across vars; surface the
  # invariant here so plan fails loudly.
  lifecycle {
    precondition {
      condition     = !contains(local.ct_core_classes, var.account_class) || var.atmos_external_id != ""
      error_message = "account_class=${var.account_class} is a CT-core class - atmos_external_id must be set to a non-empty per-org UUID. An empty ExternalId would silently lock everyone out of AtmosDeploymentRole."
    }
  }

  tags = module.this.tags
}

resource "aws_iam_role_policy_attachment" "deployment_admin" {
  provider   = aws.target
  count      = local.enabled ? 1 : 0
  role       = aws_iam_role.deployment[0].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ---------------------------------------------------------------------------
# AtmosDeploymentRole-ReadOnly - PR plan identity. Trusted by AtmosPlanOnlyRole.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "readonly_trust" {
  provider = aws.target

  statement {
    sid     = "AllowAssumeFromPlanOnly"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [local.plan_only_arn]
    }

    dynamic "condition" {
      for_each = local.require_external_id ? [1] : []
      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [var.atmos_external_id]
      }
    }

    condition {
      test     = "StringLike"
      variable = "aws:userid"
      values = [
        "AROA*:atmos-aft",
        "AROA*:atmos-aft-bootstrap",
      ]
    }
  }
}

data "aws_iam_policy_document" "readonly_inline" {
  provider = aws.target

  statement {
    sid    = "OrgDescribe"
    effect = "Allow"
    actions = [
      "organizations:Describe*",
      "organizations:List*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "readonly" {
  provider = aws.target
  count    = local.enabled ? 1 : 0

  name                 = "AtmosDeploymentRole-ReadOnly"
  description          = "Plan-only identity for pr.yaml in ${var.account_class}. ReadOnlyAccess + organizations:Describe*."
  assume_role_policy   = data.aws_iam_policy_document.readonly_trust.json
  max_session_duration = var.max_session_duration

  tags = module.this.tags
}

resource "aws_iam_role_policy_attachment" "readonly_managed" {
  provider   = aws.target
  count      = local.enabled ? 1 : 0
  role       = aws_iam_role.readonly[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "readonly_inline" {
  provider = aws.target
  count    = local.enabled ? 1 : 0
  name     = "OrganizationsDescribe"
  role     = aws_iam_role.readonly[0].id
  policy   = data.aws_iam_policy_document.readonly_inline.json
}
