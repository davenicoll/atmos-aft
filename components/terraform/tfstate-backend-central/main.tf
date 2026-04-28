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
# parses each element as a complete policy with Version + Statement -
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

# Explicit KMS key + alias. The cloudposse/tfstate-backend module's
# kms_master_key_id input is "use this existing key", NOT "create one with
# this alias" - passing it without the key existing leaves the bucket
# encryption pointing at a missing alias, and the data source lookup below
# returns 'empty result'. Own the key here so the contract is unambiguous.
module "kms_key" {
  source  = "cloudposse/kms-key/aws"
  version = "0.12.2"

  description             = "Encrypts the central tfstate bootstrap bucket."
  deletion_window_in_days = 7
  enable_key_rotation     = true
  alias                   = local.kms_alias

  context = module.this.context
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

  # Use the key from kms_key module above; tfstate-backend won't create one.
  kms_master_key_id = module.kms_key.key_id

  source_policy_documents = local.enabled ? [data.aws_iam_policy_document.bucket_extra[0].json] : []

  context = module.this.context
}

# Override the module-created CMK policy to match atmos-model.md §9.3.2
# simplified shape for the bootstrap bucket: root + central full + readall decrypt-only.
resource "aws_kms_key_policy" "this" {
  count = local.enabled ? 1 : 0

  key_id = module.kms_key.key_id

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
