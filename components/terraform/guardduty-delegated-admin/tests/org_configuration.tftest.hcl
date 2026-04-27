# Phase 2 - runs in the audit (delegated-admin) account. Owns the
# org-wide aws_guardduty_organization_configuration plus detector-level
# feature toggles delegated to the cloudposse/guardduty/aws module.

mock_provider "aws" {}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "guardduty-delegated-admin"
}

run "default_declares_detector_and_org_config" {
  command = plan

  assert {
    condition     = length(aws_guardduty_organization_configuration.this) == 1
    error_message = "Phase 2 must declare exactly one aws_guardduty_organization_configuration - org-wide enable lives here, not in the wrapped module."
  }

  assert {
    condition     = aws_guardduty_organization_configuration.this[0].auto_enable_organization_members == "ALL"
    error_message = "auto_enable_organization_members must default to ALL."
  }
}

run "auto_enable_new_propagates" {
  command = plan

  variables {
    auto_enable_organization_members = "NEW"
  }

  assert {
    condition     = aws_guardduty_organization_configuration.this[0].auto_enable_organization_members == "NEW"
    error_message = "auto_enable_organization_members must echo the variable (catalog default is NEW)."
  }
}

run "feature_toggles_default_all_on" {
  command = plan

  # The wrapped cloudposse module only re-exports `guardduty_detector`,
  # `sns_topic`, and `sns_topic_subscriptions`, not its internal feature
  # resources. Assert on var.X - these flags are passed straight through
  # to detector_feature count gates inside the module.
  assert {
    condition = alltrue([
      var.s3_protection_enabled,
      var.eks_protection_enabled,
      var.malware_protection_enabled,
      var.runtime_monitoring_enabled,
      var.lambda_network_logs_enabled,
    ])
    error_message = "All five detector-feature toggles must default to true (matches catalog default)."
  }
}

run "feature_toggles_off_propagate" {
  command = plan

  variables {
    s3_protection_enabled       = false
    eks_protection_enabled      = false
    malware_protection_enabled  = false
    runtime_monitoring_enabled  = false
    lambda_network_logs_enabled = false
  }

  assert {
    condition     = !var.s3_protection_enabled && !var.eks_protection_enabled && !var.malware_protection_enabled && !var.runtime_monitoring_enabled && !var.lambda_network_logs_enabled
    error_message = "All five feature toggles must accept false."
  }
}

run "frequency_propagates_to_detector" {
  command = plan

  variables {
    finding_publishing_frequency = "ONE_HOUR"
  }

  assert {
    condition     = module.guardduty.guardduty_detector.finding_publishing_frequency == "ONE_HOUR"
    error_message = "finding_publishing_frequency must propagate to aws_guardduty_detector via the module output."
  }
}

run "disabled_module_drops_org_configuration" {
  command = plan

  variables {
    enabled = false
  }

  assert {
    condition     = length(aws_guardduty_organization_configuration.this) == 0
    error_message = "With enabled=false, the org-configuration resource must not be declared."
  }
}
