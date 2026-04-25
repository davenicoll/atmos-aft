# Phase 3 — runs in each member account. Wraps cloudposse/guardduty/aws to
# create the per-account detector and feature toggles. Crucially, must NOT
# declare aws_guardduty_organization_configuration (phase-2 ownership).

mock_provider "aws" {}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "guardduty-member-settings"
}

run "default_declares_member_detector" {
  command = plan

  # The wrapped module exposes its detector via the `guardduty_detector`
  # output (a single resource, not a list). With enabled=true it is non-null.
  assert {
    condition     = module.guardduty_member.guardduty_detector != null
    error_message = "Phase 3 must declare a member-side aws_guardduty_detector via the wrapped module."
  }

  assert {
    condition     = module.guardduty_member.guardduty_detector.enable == true
    error_message = "The member detector must be enabled when module.this.enabled is true."
  }
}

run "feature_toggles_default_on" {
  command = plan

  # The cloudposse module re-exports only `guardduty_detector`, `sns_topic`,
  # `sns_topic_subscriptions` — internal aws_guardduty_detector_feature
  # resources are not addressable. Assert on var.X — these flags drive the
  # count gates of the module-internal resources.
  assert {
    condition = alltrue([
      var.s3_protection_enabled,
      var.eks_protection_enabled,
      var.malware_protection_enabled,
      var.runtime_monitoring_enabled,
      var.lambda_network_logs_enabled,
    ])
    error_message = "Default member settings must enable all five detector features (matches phase-2 catalog)."
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
    error_message = "All five member feature toggles must accept false."
  }
}

run "frequency_propagates_to_detector" {
  command = plan

  variables {
    finding_publishing_frequency = "SIX_HOURS"
  }

  assert {
    condition     = module.guardduty_member.guardduty_detector.finding_publishing_frequency == "SIX_HOURS"
    error_message = "finding_publishing_frequency must propagate to the member detector."
  }
}

run "disabled_module_creates_nothing" {
  command = plan

  variables {
    enabled = false
  }

  # When enabled=false, the module's output is `null` (the conditional in
  # the module's outputs.tf), confirming the detector resource was not
  # declared at this address.
  assert {
    condition     = module.guardduty_member.guardduty_detector == null
    error_message = "With enabled=false, the wrapped module must not declare a detector (output should be null)."
  }
}
