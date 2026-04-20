# GuardDuty org rollout has 3 phases that must apply in order:
#   phase 1: delegated-admin enablement (ct-mgmt account)
#   phase 2: organization-wide detector settings (audit account — delegated admin)
#   phase 3: member-account acceptance (every other account)
#
# Applying phase 2 before phase 1 leaves the audit account without delegation
# rights; applying phase 3 before phase 2 silently drops member detectors.
# See gha-design.md §4.7 and module-inventory.md §0.3.
#
# This policy can only verify *declared* dependencies — cross-stack apply order
# is enforced at the workflow layer. Here we check that every phase-2/3
# component declares `metadata.depends_on` pointing at the prior phase.
package atmos.guardduty

import rego.v1

deny contains msg if {
	some stack_name, stack in input
	some comp_name, comp in stack.components.terraform
	_is_guardduty(comp)
	phase := _phase(comp)
	phase >= 2
	not _declares_prior_phase(comp, phase)
	msg := sprintf(
		"stack %q component %q is GuardDuty phase %d but metadata.depends_on does not reference a phase-%d component",
		[stack_name, comp_name, phase, phase - 1],
	)
}

# A component that sits in the guardduty family without a declared phase is
# ambiguous — force the author to be explicit.
deny contains msg if {
	some stack_name, stack in input
	some comp_name, comp in stack.components.terraform
	_is_guardduty(comp)
	not _has_phase(comp)
	msg := sprintf(
		"stack %q component %q is GuardDuty but metadata.phase is not set (must be 1, 2, or 3)",
		[stack_name, comp_name],
	)
}

_is_guardduty(comp) if {
	src := _source(comp)
	contains(src, "guardduty")
}

_has_phase(comp) if {
	is_number(comp.metadata.phase)
}

_phase(comp) := p if {
	p := comp.metadata.phase
}

_declares_prior_phase(comp, phase) if {
	some dep in comp.metadata.depends_on
	dep.phase == phase - 1
}

_source(comp) := src if {
	src := comp.component
} else := src if {
	src := comp.metadata.component
} else := ""
