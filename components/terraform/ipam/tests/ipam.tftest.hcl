# Verifies the IPAM topology: one ipam, one private scope, one top-level
# pool, one CIDR provisioned into that pool. Also locks operating_regions
# fan-out shape.
#
# NOTE: This component does NOT expose an `allocation_default_netmask_length`
# input on aws_vpc_ipam_pool.top - child accounts that want a default mask
# size for sub-pool allocations have to set it explicitly. We document the
# absence here rather than fix it; see audit/2026-04 for context.

mock_provider "aws" {}

variables {
  region            = "us-east-1"
  namespace         = "test"
  stage             = "test"
  name              = "ipam"
  operating_regions = ["us-east-1", "eu-west-1"]
  top_pool_cidr     = "10.0.0.0/8"
}

run "default_topology_is_one_each_of_ipam_scope_pool_cidr" {
  command = plan

  assert {
    condition     = length(aws_vpc_ipam.this) == 1
    error_message = "Exactly one aws_vpc_ipam must be declared."
  }

  assert {
    condition     = length(aws_vpc_ipam_scope.private) == 1
    error_message = "Exactly one private scope must be declared."
  }

  assert {
    condition     = length(aws_vpc_ipam_pool.top) == 1
    error_message = "Exactly one top-level pool must be declared."
  }

  assert {
    condition     = length(aws_vpc_ipam_pool_cidr.top) == 1
    error_message = "Exactly one CIDR provisioning resource must be declared."
  }
}

run "operating_regions_fan_out_to_dynamic_blocks" {
  command = plan

  # Each entry in var.operating_regions becomes one operating_regions
  # sub-block on aws_vpc_ipam. With two regions in the test fixture, we
  # expect two blocks.
  assert {
    condition     = length(aws_vpc_ipam.this[0].operating_regions) == 2
    error_message = "operating_regions list of length 2 must emit two operating_regions sub-blocks."
  }
}

run "top_pool_uses_ipv4_and_region_locale" {
  command = plan

  assert {
    condition     = aws_vpc_ipam_pool.top[0].address_family == "ipv4"
    error_message = "Top-level pool must be ipv4 (IPv6 fan-out is out of scope for this component)."
  }

  assert {
    condition     = aws_vpc_ipam_pool.top[0].locale == "us-east-1"
    error_message = "Top-level pool locale must echo var.region."
  }
}

run "top_pool_does_not_set_allocation_default_netmask_length" {
  command = plan

  # Documented gap: the component does not surface an input for the pool's
  # allocation_default_netmask_length. Whatever the AWS API default is, we
  # ride it. This test snapshots the current state so a future change that
  # adds the field is forced through a deliberate update of this test.
  assert {
    condition     = aws_vpc_ipam_pool.top[0].allocation_default_netmask_length == 0 || aws_vpc_ipam_pool.top[0].allocation_default_netmask_length == null
    error_message = "Top-level pool must NOT set allocation_default_netmask_length (current behavior). Adding the field is a deliberate API change - update this test in lock-step."
  }
}

run "top_pool_cidr_propagates_to_provisioning_resource" {
  command = plan

  assert {
    condition     = aws_vpc_ipam_pool_cidr.top[0].cidr == "10.0.0.0/8"
    error_message = "var.top_pool_cidr must propagate verbatim into aws_vpc_ipam_pool_cidr.top.cidr."
  }
}

run "disabled_module_drops_all_resources" {
  command = plan

  variables {
    enabled = false
  }

  assert {
    condition = alltrue([
      length(aws_vpc_ipam.this) == 0,
      length(aws_vpc_ipam_scope.private) == 0,
      length(aws_vpc_ipam_pool.top) == 0,
      length(aws_vpc_ipam_pool_cidr.top) == 0,
    ])
    error_message = "module.this.enabled=false must drop all four IPAM resources."
  }
}
