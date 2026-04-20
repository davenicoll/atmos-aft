locals {
  enabled = module.this.enabled

  # OIDC trust fragments. Deploy paths pin to main + environments; plan-only pins to pull_request.
  deploy_sub_claims = [
    "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
    "repo:${var.github_org}/${var.github_repo}:environment:aft-mgmt",
    "repo:${var.github_org}/${var.github_repo}:environment:vended",
    "repo:${var.github_org}/${var.github_repo}:environment:core",
  ]

  plan_only_sub_claims = [
    "repo:${var.github_org}/${var.github_repo}:pull_request",
  ]
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# AtmosCentralDeploymentRole — first hop after OIDC. Fan-out root.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "central_trust" {
  statement {
    sid     = "AllowGitHubOIDCDeploy"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.deploy_sub_claims
    }
  }
}

data "aws_iam_policy_document" "central_assume_targets" {
  statement {
    sid    = "AllowAssumeIntoTargetAccounts"
    effect = "Allow"
    actions = ["sts:AssumeRole"]
    resources = [
      "arn:aws:iam::*:role/AtmosDeploymentRole",
      "arn:aws:iam::*:role/AWSControlTowerExecution",
      "arn:aws:iam::*:role/OrganizationAccountAccessRole",
    ]
  }

  statement {
    sid    = "AllowAssumeLocalReadAll"
    effect = "Allow"
    actions = ["sts:AssumeRole"]
    resources = [aws_iam_role.read_all_state[0].arn]
  }
}

resource "aws_iam_role" "central" {
  count = local.enabled ? 1 : 0

  name                 = "AtmosCentralDeploymentRole"
  description          = "Central deployment role — first hop after GitHub OIDC for all Atmos workflows."
  assume_role_policy   = data.aws_iam_policy_document.central_trust.json
  max_session_duration = var.max_session_duration

  tags = module.this.tags
}

resource "aws_iam_role_policy_attachment" "central_admin" {
  count      = local.enabled ? 1 : 0
  role       = aws_iam_role.central[0].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy" "central_assume" {
  count  = local.enabled ? 1 : 0
  name   = "AssumeTargetAndReadAllRoles"
  role   = aws_iam_role.central[0].id
  policy = data.aws_iam_policy_document.central_assume_targets.json
}

# ---------------------------------------------------------------------------
# AtmosPlanOnlyRole — PR plan identity. Only trusts pull_request OIDC.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "plan_only_trust" {
  statement {
    sid     = "AllowGitHubOIDCPullRequest"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.plan_only_sub_claims
    }
  }
}

data "aws_iam_policy_document" "plan_only_inline" {
  statement {
    sid       = "AllowAssumeReadOnlyTargets"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::*:role/AtmosDeploymentRole-ReadOnly"]
  }

  statement {
    sid    = "ReadStateBuckets"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetBucketVersioning",
    ]
    resources = [
      "arn:aws:s3:::atmos-tfstate-*",
      "arn:aws:s3:::atmos-tfstate-*/*",
    ]
  }

  statement {
    sid    = "DecryptStateKMS"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["s3.*.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "plan_only" {
  count = local.enabled ? 1 : 0

  name                 = "AtmosPlanOnlyRole"
  description          = "Plan-only identity for pr.yaml. Assumes *:role/AtmosDeploymentRole-ReadOnly in targets."
  assume_role_policy   = data.aws_iam_policy_document.plan_only_trust.json
  max_session_duration = var.max_session_duration

  tags = module.this.tags
}

resource "aws_iam_role_policy" "plan_only_inline" {
  count  = local.enabled ? 1 : 0
  name   = "PlanOnlyReadAndAssume"
  role   = aws_iam_role.plan_only[0].id
  policy = data.aws_iam_policy_document.plan_only_inline.json
}

# ---------------------------------------------------------------------------
# AtmosReadAllStateRole — drift-summary aggregator. Same-account trust only.
# Read-only enforced by permissions boundary.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "read_all_trust" {
  statement {
    sid     = "AllowCentralDeploymentRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/AtmosCentralDeploymentRole"]
    }
  }
}

data "aws_iam_policy_document" "read_all_inline" {
  statement {
    sid    = "ReadAllStateBuckets"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetBucketVersioning",
    ]
    resources = [
      "arn:aws:s3:::atmos-tfstate-*",
      "arn:aws:s3:::atmos-tfstate-*/*",
    ]
  }

  statement {
    sid    = "DecryptAllStateKMS"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["s3.*.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "read_all_boundary" {
  statement {
    sid     = "AllowReadActions"
    effect  = "Allow"
    actions = [
      "s3:Get*",
      "s3:List*",
      "kms:Decrypt",
      "kms:DescribeKey",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyAllWriteActions"
    effect = "Deny"
    actions = [
      "s3:Put*",
      "s3:Delete*",
      "s3:*ObjectLockConfiguration",
      "kms:Encrypt*",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
      "kms:Create*",
      "kms:Update*",
      "kms:Delete*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "read_all_boundary" {
  count = local.enabled ? 1 : 0

  name        = "AtmosReadAllStateRoleBoundary"
  description = "Permissions boundary enforcing read-only for AtmosReadAllStateRole. Deny statements take precedence."
  policy      = data.aws_iam_policy_document.read_all_boundary.json
}

resource "aws_iam_role" "read_all_state" {
  count = local.enabled ? 1 : 0

  name                 = "AtmosReadAllStateRole"
  description          = "Read-only cross-account state aggregator for drift summaries. Trusted only by AtmosCentralDeploymentRole in same account."
  assume_role_policy   = data.aws_iam_policy_document.read_all_trust.json
  permissions_boundary = aws_iam_policy.read_all_boundary[0].arn
  max_session_duration = var.max_session_duration

  tags = module.this.tags
}

resource "aws_iam_role_policy" "read_all_inline" {
  count  = local.enabled ? 1 : 0
  name   = "ReadAllStateAndKMS"
  role   = aws_iam_role.read_all_state[0].id
  policy = data.aws_iam_policy_document.read_all_inline.json
}
