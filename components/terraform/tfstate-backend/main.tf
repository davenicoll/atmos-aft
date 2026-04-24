locals {
  enabled = module.this.enabled

  bucket_name = coalesce(
    var.bucket_name_override,
    format("atmos-tfstate-%s-%s", data.aws_caller_identity.current.account_id, var.region),
  )

  kms_alias = coalesce(var.kms_alias_override, "alias/atmos-tfstate")

  read_all_state_role_arn = format(
    "arn:aws:iam::%s:role/AtmosReadAllStateRole",
    var.aft_mgmt_account_id,
  )

  deployment_role_arn = format(
    "arn:aws:iam::%s:role/AtmosDeploymentRole",
    data.aws_caller_identity.current.account_id,
  )

  central_role_arn = format(
    "arn:aws:iam::%s:role/AtmosCentralDeploymentRole",
    var.aft_mgmt_account_id,
  )
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Supplementary bucket policy: DenyInsecureTransport + cross-account read for AtmosReadAllStateRole.
# Merged into the module-generated policy via source_policy_documents.
data "aws_iam_policy_document" "bucket_extra" {
  count = local.enabled ? 1 : 0

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}",
      "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AtmosReadAllStateRoleRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}",
      "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}/*",
    ]
    principals {
      type        = "AWS"
      identifiers = [local.read_all_state_role_arn]
    }
  }
}

module "tfstate_backend" {
  source  = "cloudposse/tfstate-backend/aws"
  version = "1.9.0"

  s3_bucket_name = local.bucket_name

  # S3 native locking — no DynamoDB. Requires Terraform >= 1.10.
  dynamodb_enabled      = false
  s3_state_lock_enabled = true

  # SSE-KMS with module-owned CMK; key policy is re-applied via the sibling
  # aws_kms_key_policy below. v1.9.0 takes an alias name in kms_master_key_id.
  sse_encryption    = "aws:kms"
  kms_master_key_id = local.kms_alias

  force_destroy           = false
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  source_policy_documents = local.enabled ? [data.aws_iam_policy_document.bucket_extra[0].json] : []

  context = module.this.context
}

# Key policy override. Re-applies the full policy per atmos-model.md §9.3.2:
#   - account root: kms:*
#   - local AtmosDeploymentRole: full crypto
#   - aft-mgmt AtmosCentralDeploymentRole: full crypto (delegated admin path)
#   - AtmosReadAllStateRole: kms:Decrypt only, scoped via ViaService condition
data "aws_iam_policy_document" "kms_key_policy" {
  count = local.enabled ? 1 : 0

  statement {
    sid       = "AccountRoot"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid    = "DeploymentRoles"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.deployment_role_arn, local.central_role_arn]
    }
  }

  statement {
    sid       = "ReadAllStateDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.read_all_state_role_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
  }
}

# v1.9.0 does not expose the CMK id as an output; look it up via the alias we
# passed in so we can re-apply the key policy below.
data "aws_kms_alias" "tfstate" {
  count      = local.enabled ? 1 : 0
  name       = local.kms_alias
  depends_on = [module.tfstate_backend]
}

resource "aws_kms_key_policy" "this" {
  count = local.enabled ? 1 : 0

  key_id = data.aws_kms_alias.tfstate[0].target_key_id
  policy = data.aws_iam_policy_document.kms_key_policy[0].json

  # Losing this policy would lock every deployment role out of the state CMK.
  # The underlying bucket + key are module-owned, so this is the only
  # directly-declared protection surface available here.
  lifecycle {
    prevent_destroy = true
  }
}
