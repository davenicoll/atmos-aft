# Phase 3 of 3. Runs inside each member account. Creates the per-account
# detector and sets feature overrides. Keep the detector feature flags
# in sync with guardduty-delegated-admin unless a specific account needs
# to differ.
#
# Org-level auto-enable is owned by phase 2 (guardduty-delegated-admin).
# Member-level config only -- this component must pass
# auto_enable_organization_members = "NONE" semantics by NEVER managing
# aws_guardduty_organization_configuration here.

module "guardduty_member" {
  source  = "cloudposse/guardduty/aws"
  version = "1.0.0"

  finding_publishing_frequency = var.finding_publishing_frequency

  s3_protection_enabled                           = var.s3_protection_enabled
  kubernetes_audit_logs_enabled                   = var.eks_protection_enabled
  malware_protection_scan_ec2_ebs_volumes_enabled = var.malware_protection_enabled
  runtime_monitoring_enabled                      = var.runtime_monitoring_enabled
  lambda_network_logs_enabled                     = var.lambda_network_logs_enabled

  context = module.this.context
}

# Marker: auto_enable_organization_members = "NONE" is enforced by NOT
# managing aws_guardduty_organization_configuration in this phase.
