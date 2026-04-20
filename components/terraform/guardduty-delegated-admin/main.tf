# Phase 2 of 3. Runs in the delegated-admin (security/audit) account.
# Owns the org-wide GuardDuty config + detector-level features.

module "guardduty" {
  source  = "cloudposse/guardduty/aws"
  version = "1.0.0"

  finding_publishing_frequency = var.finding_publishing_frequency

  # Org-wide enable — module handles aws_guardduty_organization_configuration.
  auto_enable_organization_members = var.auto_enable_organization_members

  # Detector features
  s3_protection_enabled            = var.s3_protection_enabled
  eks_protection_enabled           = var.eks_protection_enabled
  malware_protection_enabled       = var.malware_protection_enabled
  runtime_monitoring_enabled       = var.runtime_monitoring_enabled
  lambda_network_logs_enabled      = var.lambda_network_logs_enabled

  context = module.this.context
}
