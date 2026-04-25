# Verifies the primary public Route53 zone wiring: name flows from var.zone_name,
# default comment, force_destroy is hard-coded false (safety guard against
# accidental zone deletion), and the enabled gate.

mock_provider "aws" {}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "dns-primary"
  zone_name = "example.com"
}

run "default_creates_one_zone" {
  command = plan

  assert {
    condition     = length(aws_route53_zone.primary) == 1
    error_message = "When enabled (default), exactly one aws_route53_zone.primary must be declared."
  }

  assert {
    condition     = aws_route53_zone.primary[0].name == "example.com"
    error_message = "Zone name must come from var.zone_name."
  }

  assert {
    condition     = aws_route53_zone.primary[0].force_destroy == false
    error_message = "force_destroy must be hard-coded false — safety guard against accidental zone deletion."
  }
}

run "default_comment_is_atmos_aft_primary" {
  command = plan

  assert {
    condition     = aws_route53_zone.primary[0].comment == "Atmos-AFT primary zone"
    error_message = "Default comment must be 'Atmos-AFT primary zone'."
  }
}

run "comment_override_is_honored" {
  command = plan

  variables {
    comment = "custom-zone-comment"
  }

  assert {
    condition     = aws_route53_zone.primary[0].comment == "custom-zone-comment"
    error_message = "var.comment override must flow into the zone resource."
  }
}

run "disabled_creates_no_zone" {
  command = plan

  variables {
    enabled = false
  }

  assert {
    condition     = length(aws_route53_zone.primary) == 0
    error_message = "When enabled=false, no zone resource must be declared."
  }
}

run "zone_name_output_echoes_var" {
  command = plan

  variables {
    zone_name = "atmos.example.org"
  }

  assert {
    condition     = output.zone_name == "atmos.example.org"
    error_message = "zone_name output must echo var.zone_name."
  }
}
