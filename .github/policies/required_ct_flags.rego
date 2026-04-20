# Guards against Atmos components stepping on state Control Tower already owns.
#
# Historical note: this file previously required aws-config components to set
# create_recorder=false / create_iam_role=false on the grounds that the
# top-level cloudposse/terraform-aws-config module creates a recorder that
# collides with CT's recorder. Since #36 we wrap only the recorder-free
# submodules (cis-1-2-rules, conformance-pack), which don't expose those
# vars at all — so the guard became a contradiction (denying components for
# not setting vars they can't set). That clause was removed; the structural
# guard "don't wrap the top-level module" now lives in
# forbidden_components.rego (denies cloudposse/config/aws sources without a
# //modules/ submodule anchor).
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
