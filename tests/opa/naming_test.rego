package atmos.naming_test

import rego.v1

import data.atmos.naming

# --- positive cases (should NOT deny) --------------------------------------

test_allows_core_gbl_mgmt if {
	result := naming.deny with input as {"core-gbl-mgmt": {}}
	count(result) == 0
}

test_allows_plat_use1_dev if {
	result := naming.deny with input as {"plat-use1-dev": {}}
	count(result) == 0
}

test_allows_plat_euw1_prod if {
	result := naming.deny with input as {"plat-euw1-prod": {}}
	count(result) == 0
}

test_allows_tenant_with_digits_in_env_segment if {
	result := naming.deny with input as {"plat-apne1-staging": {}}
	count(result) == 0
}

test_allows_multiple_valid_stacks if {
	result := naming.deny with input as {
		"core-gbl-mgmt": {},
		"core-gbl-audit": {},
		"plat-use1-dev": {},
	}
	count(result) == 0
}

# --- negative cases (should deny) ------------------------------------------

test_denies_two_segment_name if {
	result := naming.deny with input as {"plat-dev": {}}
	count(result) == 1
}

test_denies_four_segment_name if {
	result := naming.deny with input as {"plat-use1-dev-extra": {}}
	count(result) == 1
}

test_denies_uppercase_segment if {
	result := naming.deny with input as {"Plat-use1-dev": {}}
	count(result) == 1
}

test_denies_underscore_separator if {
	result := naming.deny with input as {"plat_use1_dev": {}}
	count(result) == 1
}

test_denies_unknown_stage if {
	result := naming.deny with input as {"plat-use1-playground": {}}
	count(result) == 1
}

test_denies_segment_starting_with_digit if {
	result := naming.deny with input as {"1plat-use1-dev": {}}
	count(result) == 1
}
