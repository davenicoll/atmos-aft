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
		"component": "guardduty-delegated-admin",
		"metadata": {
			"phase": 2,
			"depends_on": [{"phase": 1, "component": "guardduty-root"}],
		},
	}}}}}
	count(result) == 0
}

test_allows_phase_3_that_declares_phase_2_dependency if {
	result := guardduty.deny with input as {"plat-use1-dev": {"components": {"terraform": {"gd-member": {
		"component": "guardduty-member-settings",
		"metadata": {
			"phase": 3,
			"depends_on": [{"phase": 2, "component": "guardduty-delegated-admin"}],
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
		"component": "guardduty-delegated-admin",
		"metadata": {"phase": 2},
	}}}}}
	count(result) == 1
}

test_denies_phase_3_depending_only_on_phase_1 if {
	result := guardduty.deny with input as {"plat-use1-dev": {"components": {"terraform": {"gd-member": {
		"component": "guardduty-member-settings",
		"metadata": {
			"phase": 3,
			"depends_on": [{"phase": 1, "component": "guardduty-root"}],
		},
	}}}}}
	count(result) == 1
}

test_denies_phase_2_with_empty_depends_on if {
	result := guardduty.deny with input as {"audit-gbl-audit": {"components": {"terraform": {"gd-org": {
		"component": "guardduty-delegated-admin",
		"metadata": {"phase": 2, "depends_on": []},
	}}}}}
	count(result) == 1
}

# --- phase-value validation (F1) -------------------------------------------

test_denies_phase_zero if {
	result := guardduty.deny with input as {"plat-use1-dev": {"components": {"terraform": {"gd": {
		"component": "guardduty-root",
		"metadata": {"phase": 0},
	}}}}}
	count(result) >= 1
}

test_denies_phase_ninety_nine if {
	result := guardduty.deny with input as {"plat-use1-dev": {"components": {"terraform": {"gd": {
		"component": "guardduty-root",
		"metadata": {"phase": 99},
	}}}}}
	count(result) >= 1
}

test_denies_non_integer_phase if {
	result := guardduty.deny with input as {"plat-use1-dev": {"components": {"terraform": {"gd": {
		"component": "guardduty-root",
		"metadata": {"phase": 1.5},
	}}}}}
	count(result) >= 1
}

test_denies_phase_zero_on_non_guardduty_component if {
	# Invalid phase values must be rejected regardless of component family —
	# catches stray metadata.phase on non-guardduty components too.
	result := guardduty.deny with input as {"plat-use1-dev": {"components": {"terraform": {"vpc": {
		"component": "vpc",
		"metadata": {"phase": 0},
	}}}}}
	count(result) == 1
}

# --- depends_on.component name validation (F1) -----------------------------

test_denies_phase_2_with_wrong_upstream_component_name if {
	# depends_on.phase is correct (1) but component name does not match the
	# canonical phase-1 component — should deny.
	result := guardduty.deny with input as {"audit-gbl-audit": {"components": {"terraform": {"gd-org": {
		"component": "guardduty-delegated-admin",
		"metadata": {
			"phase": 2,
			"depends_on": [{"phase": 1, "component": "not-the-real-phase-1-component"}],
		},
	}}}}}
	count(result) == 1
}

test_denies_phase_3_with_wrong_upstream_component_name if {
	result := guardduty.deny with input as {"plat-use1-dev": {"components": {"terraform": {"gd-member": {
		"component": "guardduty-member-settings",
		"metadata": {
			"phase": 3,
			"depends_on": [{"phase": 2, "component": "guardduty-wrong-name"}],
		},
	}}}}}
	count(result) == 1
}
