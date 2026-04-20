locals {
  enabled = module.this.enabled

  bucket_name = "atmos-tfstate-bootstrap-${var.aft_mgmt_account_id}-${var.region}"
  kms_alias   = "alias/atmos-tfstate-bootstrap"

  central_role_principal = "arn:aws:iam::${var.aft_mgmt_account_id}:role/AtmosCentralDeploymentRole"
  readall_role_principal = "arn:aws:iam::${var.aft_mgmt_account_id}:role/AtmosReadAllStateRole"

  extra_bucket_statements = local.enabled ? jsonencode([
    {
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        "arn:aws:s3:::${local.bucket_name}",
        "arn:aws:s3:::${local.bucket_name}/*",
      ]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    },
    {
      Sid       = "AllowReadAllStateRoleRead"
      Effect    = "Allow"
      Principal = { AWS = local.readall_role_principal }
      Action = [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:GetBucketVersioning",
      ]
      Resource = [
        "arn:aws:s3:::${local.bucket_name}",
        "arn:aws:s3:::${local.bucket_name}/*",
      ]
    },
  ]) : "[]"
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

  source_policy_documents = [local.extra_bucket_statements]

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
        Principal = { AWS = "arn:aws:iam::${var.aft_mgmt_account_id}:root" }
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
}
