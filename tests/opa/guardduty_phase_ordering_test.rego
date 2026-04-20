package atmos.guardduty_test

import rego.v1

import data.atmos.guardduty

# --- positive cases (should NOT deny) --------------------------------------

test_allows_phase_1_without_dependency if {
	result := guardduty.deny with input as {"core-gbl-mgmt": {"components": {"terraform": {"gd-admin": {
		"component": "guardduty-delegated-admin",
		"metadata": {"phase": 1},
	}}}}}
	count(result) == 0
}

test_allows_phase_2_that_declares_phase_1_dependency if {
	result := guardduty.deny with input as {"audit-gbl-audit": {"components": {"terraform": {"gd-org": {
		"component": "guardduty-organization-settings",
		"metadata": {
			"phase": 2,
			"depends_on": [{"phase": 1, "component": "guardduty-delegated-admin"}],
		},
	}}}}}
	count(result) == 0
}

test_allows_phase_3_that_declares_phase_2_dependency if {
	result := guardduty.deny with input as {"plat-use1-dev": {"components": {"terraform": {"gd-member": {
		"component": "guardduty-root",
		"metadata": {
			"phase": 3,
			"depends_on": [{"phase": 2, "component": "guardduty-organization-settings"}],
		},
	}}}}}
	count(result) == 0
}

test_allows_non_guardduty_component_without_phase if {
	result := guardduty.deny with input as {"plat-use1-dev": {"components": {"terraform": {"vpc": {"component": "vpc"}}}}}
	count(result) == 0
}

# --- negative cases (should deny) ------------------------------------------

test_denies_guardduty_component_without_phase_metadata if {
	result := guardduty.deny with input as {"plat-use1-dev": {"components": {"terraform": {"gd": {"component": "guardduty-root"}}}}}
	count(result) == 1
}

test_denies_phase_2_without_depends_on if {
	result := guardduty.deny with input as {"audit-gbl-audit": {"components": {"terraform": {"gd-org": {
		"component": "guardduty-organization-settings",
		"metadata": {"phase": 2},
	}}}}}
	count(result) == 1
}

test_denies_phase_3_depending_only_on_phase_1 if {
	result := guardduty.deny with input as {"plat-use1-dev": {"components": {"terraform": {"gd-member": {
		"component": "guardduty-root",
		"metadata": {
			"phase": 3,
			"depends_on": [{"phase": 1, "component": "guardduty-delegated-admin"}],
		},
	}}}}}
	count(result) == 1
}

test_denies_phase_2_with_empty_depends_on if {
	result := guardduty.deny with input as {"audit-gbl-audit": {"components": {"terraform": {"gd-org": {
		"component": "guardduty-organization-settings",
		"metadata": {"phase": 2, "depends_on": []},
	}}}}}
	count(result) == 1
}
