# Verifies the delegated subzone + parent NS-record wiring:
# - FQDN composition (subzone_label + parent_zone_name)
# - parent_zone_id null vs set toggles the delegation NS record
# - NS-record ttl, type, target zone_id, parent_zone_id propagation
# - enabled gate
#
# AUDIT FLAG: ttl is hard-coded to 300s. RFC standard for NS records is
# 172800s (48h). Not fixed here — flagged for follow-up.

mock_provider "aws" {}

variables {
  region           = "us-east-1"
  namespace        = "test"
  stage            = "test"
  name             = "dns-delegated"
  parent_zone_name = "example.com"
  subzone_label    = "prod"
}

run "default_creates_subzone_only" {
  # parent_zone_id defaults to null → no delegation NS record (cross-account
  # default); just the delegated zone itself.
  command = plan

  assert {
    condition     = length(aws_route53_zone.delegated) == 1
    error_message = "Subzone must be declared exactly once when enabled."
  }

  assert {
    condition     = aws_route53_zone.delegated[0].name == "prod.example.com"
    error_message = "Subzone FQDN must compose as <subzone_label>.<parent_zone_name>."
  }

  assert {
    condition     = aws_route53_zone.delegated[0].force_destroy == false
    error_message = "force_destroy must be hard-coded false."
  }

  assert {
    condition     = length(aws_route53_record.delegation) == 0
    error_message = "With parent_zone_id=null, delegation NS record must NOT be created (cross-account flow)."
  }
}

run "with_parent_zone_id_creates_delegation_ns" {
  command = plan

  variables {
    parent_zone_id = "Z0123456789ABCDEFGHIJ"
  }

  assert {
    condition     = length(aws_route53_record.delegation) == 1
    error_message = "With parent_zone_id set, exactly one NS record must be rendered in the parent zone."
  }

  assert {
    condition     = aws_route53_record.delegation[0].type == "NS"
    error_message = "Delegation record type must be NS."
  }

  assert {
    condition     = aws_route53_record.delegation[0].zone_id == "Z0123456789ABCDEFGHIJ"
    error_message = "Delegation record must target var.parent_zone_id (the parent zone)."
  }

  assert {
    condition     = aws_route53_record.delegation[0].name == "prod.example.com"
    error_message = "Delegation record name must equal the delegated subzone FQDN."
  }

  # Hard-coded TTL audit flag — see file-level comment.
  assert {
    condition     = aws_route53_record.delegation[0].ttl == 300
    error_message = "Delegation NS record ttl is currently 300s (audit-flagged: RFC standard is 172800s/48h)."
  }
}

run "subzone_label_composes_fqdn" {
  command = plan

  variables {
    parent_zone_name = "atmos.example.org"
    subzone_label    = "stg"
  }

  assert {
    condition     = aws_route53_zone.delegated[0].name == "stg.atmos.example.org"
    error_message = "FQDN must concatenate <subzone_label>.<parent_zone_name> verbatim."
  }
}

run "disabled_creates_nothing" {
  command = plan

  variables {
    enabled        = false
    parent_zone_id = "Z0123456789ABCDEFGHIJ"
  }

  assert {
    condition     = length(aws_route53_zone.delegated) == 0
    error_message = "enabled=false must skip the delegated zone."
  }

  assert {
    condition     = length(aws_route53_record.delegation) == 0
    error_message = "enabled=false must also skip the delegation NS record, even when parent_zone_id is set."
  }
}
