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

# metadata.component fallback path (component: key absent, metadata.component present).
test_denies_forbidden_source_via_metadata_component if {
	result := components.deny with input as {"core-gbl-mgmt": {"components": {"terraform": {"org": {
		"metadata": {"component": "aws-organization"},
		"vars": {},
	}}}}}
	count(result) == 1
}
