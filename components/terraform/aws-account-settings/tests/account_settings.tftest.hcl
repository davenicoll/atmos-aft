# Verifies the three account-wide settings resources gate on their feature
# toggles and that defaults flow into aws_iam_account_password_policy.

mock_provider "aws" {}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "aws-account-settings"
}

run "defaults_declare_password_policy_and_ebs_encryption" {
  command = plan

  assert {
    condition     = length(aws_iam_account_password_policy.this) == 1
    error_message = "manage_password_policy=true (default) must declare aws_iam_account_password_policy."
  }

  assert {
    condition     = length(aws_ebs_encryption_by_default.this) == 1
    error_message = "manage_ebs_encryption=true (default) must declare aws_ebs_encryption_by_default."
  }

  # ebs_default_kms_key_id defaults to null → AWS-managed aws/ebs key, no
  # custom key resource. Setting a CMK ARN in another run instantiates it.
  assert {
    condition     = length(aws_ebs_default_kms_key.this) == 0
    error_message = "Default ebs_default_kms_key_id=null must NOT declare aws_ebs_default_kms_key (use AWS-managed alias/aws/ebs)."
  }
}

run "password_policy_defaults_propagate" {
  command = plan

  # Lock in the four numeric defaults plus the always-on requirement flags.
  # Drift on any of these is a security-posture regression.
  assert {
    condition     = aws_iam_account_password_policy.this[0].minimum_password_length == 14
    error_message = "Default password_minimum_length must be 14."
  }

  assert {
    condition     = aws_iam_account_password_policy.this[0].max_password_age == 90
    error_message = "Default password_max_age must be 90 days."
  }

  assert {
    condition     = aws_iam_account_password_policy.this[0].password_reuse_prevention == 24
    error_message = "Default password_reuse_prevention must be 24."
  }

  assert {
    condition = alltrue([
      aws_iam_account_password_policy.this[0].require_lowercase_characters,
      aws_iam_account_password_policy.this[0].require_uppercase_characters,
      aws_iam_account_password_policy.this[0].require_numbers,
      aws_iam_account_password_policy.this[0].require_symbols,
      aws_iam_account_password_policy.this[0].allow_users_to_change_password,
    ])
    error_message = "All four character-class requirements + change-password must be true."
  }

  assert {
    condition     = aws_iam_account_password_policy.this[0].hard_expiry == false
    error_message = "hard_expiry must be false — true would lock users out at age expiry."
  }
}

run "manage_password_policy_false_drops_resource" {
  command = plan

  variables {
    manage_password_policy = false
  }

  assert {
    condition     = length(aws_iam_account_password_policy.this) == 0
    error_message = "manage_password_policy=false must drop the password_policy resource (e.g. shared identity accounts)."
  }
}

run "manage_ebs_encryption_false_drops_both_resources" {
  command = plan

  variables {
    manage_ebs_encryption  = false
    ebs_default_kms_key_id = "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  }

  # Even if a CMK ARN is supplied, manage_ebs_encryption=false gates BOTH
  # resources. This is the contract that lets identity accounts opt out
  # entirely.
  assert {
    condition = alltrue([
      length(aws_ebs_encryption_by_default.this) == 0,
      length(aws_ebs_default_kms_key.this) == 0,
    ])
    error_message = "manage_ebs_encryption=false must drop both EBS resources, regardless of ebs_default_kms_key_id."
  }
}

run "custom_cmk_declares_default_kms_key_resource" {
  command = plan

  variables {
    ebs_default_kms_key_id = "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  }

  assert {
    condition     = length(aws_ebs_default_kms_key.this) == 1
    error_message = "Setting ebs_default_kms_key_id with manage_ebs_encryption=true must declare aws_ebs_default_kms_key."
  }

  assert {
    condition     = aws_ebs_default_kms_key.this[0].key_arn == "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    error_message = "key_arn must echo var.ebs_default_kms_key_id verbatim."
  }
}

run "disabled_module_drops_all_resources" {
  command = plan

  variables {
    enabled = false
  }

  assert {
    condition = alltrue([
      length(aws_iam_account_password_policy.this) == 0,
      length(aws_ebs_encryption_by_default.this) == 0,
      length(aws_ebs_default_kms_key.this) == 0,
    ])
    error_message = "module.this.enabled=false must drop all three resources."
  }
}
