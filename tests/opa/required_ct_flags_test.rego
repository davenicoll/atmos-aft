package atmos.ct_flags_test

import rego.v1

import data.atmos.ct_flags

# --- positive cases (should NOT deny) --------------------------------------

test_allows_config_with_both_flags_disabled if {
	result := ct_flags.deny with input as {"plat-use1-dev": {"components": {"terraform": {"config": {
		"component": "aws-config",
		"vars": {"create_recorder": false, "create_iam_role": false},
	}}}}}
	count(result) == 0
}

test_allows_non_config_component if {
	result := ct_flags.deny with input as {"plat-use1-dev": {"components": {"terraform": {"vpc": {"component": "vpc", "vars": {}}}}}}
	count(result) == 0
}

test_allows_guardduty_member_without_org_settings if {
	result := ct_flags.deny with input as {"plat-use1-dev": {"components": {"terraform": {"gd": {
		"component": "guardduty-root",
		"vars": {"enable_organization_settings": false},
		"metadata": {"ct_managed": true},
	}}}}}
	count(result) == 0
}

test_allows_guardduty_org_component_when_not_ct_managed if {
	result := ct_flags.deny with input as {"audit-gbl-audit": {"components": {"terraform": {"gd": {
		"component": "guardduty-organization-settings",
		"vars": {"enable_organization_settings": true},
		"metadata": {"ct_managed": false},
	}}}}}
	count(result) == 0
}

# --- negative cases (should deny) ------------------------------------------

test_denies_config_missing_create_recorder_flag if {
	result := ct_flags.deny with input as {"plat-use1-dev": {"components": {"terraform": {"config": {"component": "aws-config", "vars": {"create_iam_role": false}}}}}}
	count(result) == 1
}

test_denies_config_with_create_recorder_true if {
	result := ct_flags.deny with input as {"plat-use1-dev": {"components": {"terraform": {"config": {
		"component": "aws-config",
		"vars": {"create_recorder": true, "create_iam_role": false},
	}}}}}
	count(result) == 1
}

test_denies_config_with_create_iam_role_true if {
	result := ct_flags.deny with input as {"plat-use1-dev": {"components": {"terraform": {"config": {
		"component": "aws-config",
		"vars": {"create_recorder": false, "create_iam_role": true},
	}}}}}
	count(result) == 1
}

test_denies_ct_managed_guardduty_org_with_settings_enabled if {
	result := ct_flags.deny with input as {"core-gbl-mgmt": {"components": {"terraform": {"gd": {
		"component": "guardduty-organization-settings",
		"vars": {"enable_organization_settings": true},
		"metadata": {"ct_managed": true},
	}}}}}
	count(result) == 1
}

test_denies_config_missing_both_flags if {
	result := ct_flags.deny with input as {"plat-use1-dev": {"components": {"terraform": {"config": {"component": "aws-config", "vars": {}}}}}}
	count(result) == 2
}
