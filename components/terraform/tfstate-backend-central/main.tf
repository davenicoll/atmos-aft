data "aws_partition" "current" {}

locals {
  enabled = module.this.enabled

  bucket_name = var.bucket_name
  kms_alias   = "alias/atmos-tfstate-bootstrap"

  central_role_principal = "arn:${data.aws_partition.current.partition}:iam::${var.aft_mgmt_account_id}:role/AtmosCentralDeploymentRole"
  readall_role_principal = "arn:${data.aws_partition.current.partition}:iam::${var.aft_mgmt_account_id}:role/AtmosReadAllStateRole"
}

# Supplementary bucket policy merged into the module-generated one via
# source_policy_documents. Must be a FULL policy document (the
# cloudposse/tfstate-backend module's aggregated_policy data source
# parses each element as a complete policy with Version + Statement —
# a bare statements array fails JSON validation at plan time).
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
    sid    = "AllowReadAllStateRoleRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetBucketVersioning",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}",
      "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}/*",
    ]
    principals {
      type        = "AWS"
      identifiers = [local.readall_role_principal]
    }
  }
}

module "tfstate_backend" {
  source  = "cloudposse/tfstate-backend/aws"
  version = "1.9.0"

  s3_bucket_name = local.bucket_name

  force_destroy                 = false
  sse_encryption                = "aws:kms"
  enable_point_in_time_recovery = false
  block_public_acls             = true
  block_public_policy           = true
  ignore_public_acls            = true
  restrict_public_buckets       = true

  # S3 native locking; no DynamoDB.
  dynamodb_enabled      = false
  s3_state_lock_enabled = true

  # v1.9.0 takes the alias name in kms_master_key_id (no separate alias var).
  kms_master_key_id = local.kms_alias

  source_policy_documents = local.enabled ? [data.aws_iam_policy_document.bucket_extra[0].json] : []

  context = module.this.context
}

# v1.9.0 doesn't output the CMK id; resolve it from the alias we passed in.
data "aws_kms_alias" "tfstate" {
  count      = local.enabled ? 1 : 0
  name       = local.kms_alias
  depends_on = [module.tfstate_backend]
}

# Override the module-created CMK policy to match atmos-model.md §9.3.2
# simplified shape for the bootstrap bucket: root + central full + readall decrypt-only.
resource "aws_kms_key_policy" "this" {
  count = local.enabled ? 1 : 0

  key_id = data.aws_kms_alias.tfstate[0].target_key_id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "atmos-tfstate-bootstrap-key-policy"
    Statement = [
      {
        Sid       = "EnableRootAccountPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${var.aft_mgmt_account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCentralDeploymentRoleFullUse"
        Effect    = "Allow"
        Principal = { AWS = local.central_role_principal }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
      {
        Sid       = "AllowReadAllStateRoleDecryptOnly"
        Effect    = "Allow"
        Principal = { AWS = local.readall_role_principal }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${var.region}.amazonaws.com" }
        }
      },
    ]
  })

  # Bootstrap key: if this policy is lost, every deployment role loses crypto
  # access to the central state bucket. The bucket + key are owned by the
  # cloudposse module, so this policy is the only directly-declared surface
  # available to protect here.
  lifecycle {
    prevent_destroy = true
  }
}
