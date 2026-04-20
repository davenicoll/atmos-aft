# AWS Config and related services are already bootstrapped by Control Tower in
# every CT-governed account. Components that layer on top must opt out of
# creating duplicate recorders/IAM roles or they'll conflict with CT on apply.
# See module-inventory.md §0.2 ("CT-compat flags") and mapping.md §6.
package atmos.ct_flags

import rego.v1

# Components whose source matches these substrings must set specific flags.
config_component_markers := {
	"aws-config",
	"config-storage",
}

deny contains msg if {
	some stack_name, stack in input
	some comp_name, comp in stack.components.terraform
	_is_config_component(comp)
	not _has_value(comp.vars, "create_recorder", false)
	msg := sprintf(
		"stack %q component %q (aws-config) must set vars.create_recorder=false — Control Tower already runs a recorder in this account",
		[stack_name, comp_name],
	)
}

deny contains msg if {
	some stack_name, stack in input
	some comp_name, comp in stack.components.terraform
	_is_config_component(comp)
	not _has_value(comp.vars, "create_iam_role", false)
	msg := sprintf(
		"stack %q component %q (aws-config) must set vars.create_iam_role=false — reuse the CT-provisioned role",
		[stack_name, comp_name],
	)
}

# GuardDuty organization-level components must not re-enable org-level GuardDuty
# if the stack is the CT mgmt account — CT does that. Enforced via
# `ct_managed: true` opt-in on the component metadata.
deny contains msg if {
	some stack_name, stack in input
	some comp_name, comp in stack.components.terraform
	_is_guardduty_org_component(comp)
	comp.metadata.ct_managed == true
	comp.vars.enable_organization_settings == true
	msg := sprintf(
		"stack %q component %q declares ct_managed=true but enable_organization_settings=true — CT owns org-level GuardDuty state",
		[stack_name, comp_name],
	)
}

_is_config_component(comp) if {
	src := _source(comp)
	some marker in config_component_markers
	contains(src, marker)
}

_is_guardduty_org_component(comp) if {
	src := _source(comp)
	contains(src, "guardduty")
	contains(src, "organization")
}

_source(comp) := src if {
	src := comp.component
} else := src if {
	src := comp.metadata.component
} else := ""

_has_value(obj, key, want) if {
	obj[key] == want
}
