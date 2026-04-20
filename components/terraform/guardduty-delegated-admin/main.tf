# Phase 2 of 3. Runs in the delegated-admin (security/audit) account.
# Owns the org-wide GuardDuty config + detector-level features.

module "guardduty" {
  source  = "cloudposse/guardduty/aws"
  version = "1.0.0"

  finding_publishing_frequency = var.finding_publishing_frequency

  # Detector features
  s3_protection_enabled                           = var.s3_protection_enabled
  kubernetes_audit_logs_enabled                   = var.eks_protection_enabled
  malware_protection_scan_ec2_ebs_volumes_enabled = var.malware_protection_enabled
  runtime_monitoring_enabled                      = var.runtime_monitoring_enabled
  lambda_network_logs_enabled                     = var.lambda_network_logs_enabled

  context = module.this.context
}

# Org-wide enable lives outside the module: v1.0.0 does not expose
# aws_guardduty_organization_configuration. This component runs in the
# delegated-admin account, so it owns auto_enable_organization_members for
# the org. Phase 3 (member-settings) must NOT manage this resource.
resource "aws_guardduty_organization_configuration" "this" {
  count = module.this.enabled ? 1 : 0

  detector_id                      = module.guardduty.guardduty_detector.id
  auto_enable_organization_members = var.auto_enable_organization_members
}
