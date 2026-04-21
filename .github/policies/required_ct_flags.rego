# Guards against Atmos components stepping on state Control Tower already
# owns. Currently: GuardDuty organization-level components must not re-enable
# org-level GuardDuty on stacks where CT already runs the org detector.
# (The structural guard against wrapping the top-level cloudposse/config/aws
# module lives in forbidden_components.rego.)
package atmos.ct_flags

import rego.v1

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
