# Phase 3 of 3. Runs inside each member account. Creates the per-account
# detector and sets feature overrides. Keep the detector feature flags
# in sync with guardduty-delegated-admin unless a specific account needs
# to differ.

module "guardduty_member" {
  source  = "cloudposse/guardduty/aws"
  version = "1.0.0"

  finding_publishing_frequency = var.finding_publishing_frequency
  auto_enable_organization_members = "NONE"  # member-level config only

  s3_protection_enabled       = var.s3_protection_enabled
  eks_protection_enabled      = var.eks_protection_enabled
  malware_protection_enabled  = var.malware_protection_enabled
  runtime_monitoring_enabled  = var.runtime_monitoring_enabled
  lambda_network_logs_enabled = var.lambda_network_logs_enabled

  context = module.this.context
}
