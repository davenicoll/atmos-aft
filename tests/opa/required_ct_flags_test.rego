package atmos.ct_flags_test

import rego.v1

import data.atmos.ct_flags

# --- positive cases (should NOT deny) --------------------------------------

test_allows_non_guardduty_component if {
	result := ct_flags.deny with input as {"core-gbl-mgmt": {
		"vars": {"account_class": "ct-mgmt"},
		"components": {"terraform": {"vpc": {"component": "vpc", "vars": {}}}},
	}}
	count(result) == 0
}

test_allows_guardduty_member_without_org_settings if {
	# guardduty-member-settings is not in the org-component allowlist — never denies.
	result := ct_flags.deny with input as {"plat-use1-dev": {
		"vars": {"account_class": "vended"},
		"components": {"terraform": {"gd": {
			"component": "guardduty-member-settings",
			"vars": {"enable_organization_settings": true},
		}}},
	}}
	count(result) == 0
}

test_allows_guardduty_org_component_on_non_ct_managed_stack if {
	# F2: vended-class stack is not CT-managed, so enabling org settings is fine.
	result := ct_flags.deny with input as {"plat-use1-prod": {
		"vars": {"account_class": "vended"},
		"components": {"terraform": {"gd": {
			"component": "guardduty-delegated-admin",
			"vars": {"enable_organization_settings": true},
		}}},
	}}
	count(result) == 0
}

test_allows_guardduty_org_component_on_ct_mgmt_without_org_settings if {
	# CT-managed stack is OK provided enable_organization_settings is off.
	result := ct_flags.deny with input as {"core-gbl-mgmt": {
		"vars": {"account_class": "ct-mgmt"},
		"components": {"terraform": {"gd": {
			"component": "guardduty-delegated-admin",
			"vars": {"enable_organization_settings": false},
		}}},
	}}
	count(result) == 0
}

# A non-org-level guardduty component (substring "guardduty" but not in the
# tightened allowlist) must not deny, even when org settings are enabled on a
# CT-managed stack — guards against false positives from F4 widening.
test_allows_guardduty_root_on_ct_mgmt_with_org_settings if {
	result := ct_flags.deny with input as {"core-gbl-mgmt": {
		"vars": {"account_class": "ct-mgmt"},
		"components": {"terraform": {"gd": {
			"component": "guardduty-root",
			"vars": {"enable_organization_settings": true},
		}}},
	}}
	count(result) == 0
}

# --- negative cases (should deny) ------------------------------------------

# F2: ct-mgmt stack with guardduty org component + enable_organization_settings=true → deny.
test_denies_ct_mgmt_guardduty_org_with_settings_enabled if {
	result := ct_flags.deny with input as {"core-gbl-mgmt": {
		"vars": {"account_class": "ct-mgmt"},
		"components": {"terraform": {"gd": {
			"component": "guardduty-delegated-admin",
			"vars": {"enable_organization_settings": true},
		}}},
	}}
	count(result) == 1
}

test_denies_audit_guardduty_org_with_settings_enabled if {
	result := ct_flags.deny with input as {"core-gbl-audit": {
		"vars": {"account_class": "audit"},
		"components": {"terraform": {"gd": {
			"component": "guardduty-delegated-admin",
			"vars": {"enable_organization_settings": true},
		}}},
	}}
	count(result) == 1
}

test_denies_log_archive_guardduty_org_with_settings_enabled if {
	result := ct_flags.deny with input as {"core-gbl-log-archive": {
		"vars": {"account_class": "log-archive"},
		"components": {"terraform": {"gd": {
			"component": "guardduty-delegated-admin",
			"vars": {"enable_organization_settings": true},
		}}},
	}}
	count(result) == 1
}

test_denies_aft_mgmt_guardduty_org_with_settings_enabled if {
	result := ct_flags.deny with input as {"core-gbl-mgmt": {
		"vars": {"account_class": "aft-mgmt"},
		"components": {"terraform": {"gd": {
			"component": "guardduty-delegated-admin",
			"vars": {"enable_organization_settings": true},
		}}},
	}}
	count(result) == 1
}
