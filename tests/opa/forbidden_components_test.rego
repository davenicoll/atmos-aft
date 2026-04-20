package atmos.components_test

import rego.v1

import data.atmos.components

# --- positive cases (should NOT deny) --------------------------------------

test_allows_vpc_component if {
	result := components.deny with input as {"plat-use1-dev": {"components": {"terraform": {"vpc": {"component": "vpc", "vars": {"cidr_block": "10.0.0.0/16"}}}}}}
	count(result) == 0
}

test_allows_iam_deployment_roles if {
	result := components.deny with input as {"core-gbl-mgmt": {"components": {"terraform": {"iam-roles": {"component": "iam-deployment-roles", "vars": {}}}}}}
	count(result) == 0
}

test_allows_guardduty_delegated_admin if {
	result := components.deny with input as {"core-gbl-mgmt": {"components": {"terraform": {"gd-admin": {"component": "guardduty-delegated-admin", "vars": {}}}}}}
	count(result) == 0
}

test_allows_empty_stack if {
	result := components.deny with input as {"plat-use1-dev": {"components": {"terraform": {}}}}
	count(result) == 0
}

# --- negative cases (should deny) ------------------------------------------

test_denies_aws_organization if {
	result := components.deny with input as {"core-gbl-mgmt": {"components": {"terraform": {"org": {"component": "aws-organization", "vars": {}}}}}}
	count(result) == 1
}

test_denies_aws_organizational_unit if {
	result := components.deny with input as {"core-gbl-mgmt": {"components": {"terraform": {"ou": {"component": "aws-organizational-unit", "vars": {}}}}}}
	count(result) == 1
}

test_denies_aws_account if {
	result := components.deny with input as {"core-gbl-mgmt": {"components": {"terraform": {"acct": {"component": "aws-account", "vars": {}}}}}}
	count(result) == 1
}

test_denies_raw_aws_organizations_organization_resource if {
	result := components.deny with input as {"core-gbl-mgmt": {"components": {"terraform": {"custom": {
		"component": "custom-org-wrapper",
		"vars": {},
		"metadata": {"resource_types": ["aws_organizations_organization"]},
	}}}}}
	count(result) == 1
}

test_denies_raw_account_resource_even_in_child_stack if {
	result := components.deny with input as {"plat-use1-dev": {"components": {"terraform": {"acct": {
		"component": "mine",
		"vars": {},
		"metadata": {"resource_types": ["aws_organizations_account"]},
	}}}}}
	count(result) == 1
}

# --- top-level aws-config wrapper guard ------------------------------------

test_denies_top_level_aws_config_source if {
	result := components.deny with input as {"core-gbl-mgmt": {"components": {"terraform": {"config": {
		"component": "aws-config-top-level",
		"vars": {},
		"metadata": {"terraform_sources": ["cloudposse/config/aws"]},
	}}}}}
	count(result) == 1
}

test_allows_aws_config_submodule_source if {
	result := components.deny with input as {"plat-use1-dev": {"components": {"terraform": {"config": {
		"component": "aws-config-rules",
		"vars": {},
		"metadata": {"terraform_sources": ["cloudposse/config/aws//modules/cis-1-2-rules"]},
	}}}}}
	count(result) == 0
}
