locals {
  enabled = module.this.enabled

  # Event category: Management (default). Event sources filtered via advanced event selectors.
  # Four sources: controltower, organizations, servicecatalog, sts.
  event_sources = [
    "controltower.amazonaws.com",
    "organizations.amazonaws.com",
    "servicecatalog.amazonaws.com",
    "sts.amazonaws.com",
  ]
}

resource "aws_cloudtrail_event_data_store" "this" {
  count = local.enabled ? 1 : 0

  name = module.this.id

  # 7y retention (2557 days, per task #13 spec).
  retention_period = var.retention_days

  # Single-region store unless multi_region_enabled is flipped on.
  multi_region_enabled           = var.multi_region_enabled
  organization_enabled           = false
  termination_protection_enabled = true

  # Scope: management events only, filtered to the four event sources.
  advanced_event_selector {
    name = "FilterToAftRelevantEventSources"

    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }

    field_selector {
      field  = "eventSource"
      equals = local.event_sources
    }
  }

  # KMS encryption (uses AWS-managed CloudTrail key unless kms_key_id supplied).
  kms_key_id = var.kms_key_id

  tags = module.this.tags
}
