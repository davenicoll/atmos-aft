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

# Canonical phase → Atmos component name map. Used both to validate the
# component value in metadata.depends_on entries and to document the 1:1
# mapping the policy expects.
_phase_component := {
	1: "guardduty-root",
	2: "guardduty-delegated-admin",
	3: "guardduty-member-settings",
}

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

# Any component that sets metadata.phase at all must use a valid value —
# catches typos like phase=0, phase=99, phase=1.5 even on non-guardduty
# components. The {1,2,3} set is the only valid GuardDuty phase space.
deny contains msg if {
	some stack_name, stack in input
	some comp_name, comp in stack.components.terraform
	comp.metadata.phase
	not comp.metadata.phase in {1, 2, 3}
	msg := sprintf(
		"stack %q component %q: metadata.phase=%v is not in {1, 2, 3}",
		[stack_name, comp_name, comp.metadata.phase],
	)
}

_is_guardduty(comp) if {
	src := _source(comp)
	contains(src, "guardduty")
}

# Only recognise a phase when it is one of the three canonical values. This
# mirrors the explicit deny above and means `_phase(comp)` returning nothing
# (rather than e.g. 99) for invalid inputs.
_has_phase(comp) if {
	comp.metadata.phase in {1, 2, 3}
}

_phase(comp) := p if {
	p := comp.metadata.phase
	p in {1, 2, 3}
}

# Prior-phase dependency is satisfied when the component declares a
# depends_on entry whose phase is exactly phase-1 AND whose component name
# matches the canonical component for that phase. This catches both
# "wrong phase" and "right phase, wrong component" typos.
_declares_prior_phase(comp, phase) if {
	some dep in comp.metadata.depends_on
	dep.phase == phase - 1
	dep.component == _phase_component[dep.phase]
}

_source(comp) := src if {
	src := comp.component
} else := src if {
	src := comp.metadata.component
} else := ""
