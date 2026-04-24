# Guards against Atmos components stepping on state Control Tower already
# owns. Currently: GuardDuty organization-level components must not re-enable
# org-level GuardDuty on stacks where CT already runs the org detector.
# (The structural guard against wrapping the top-level cloudposse/config/aws
# module lives in forbidden_components.rego.)
package atmos.ct_flags

import rego.v1

# Atmos component names that drive org-wide GuardDuty state. Kept as an exact
# allowlist (not a substring match) so renaming/introducing a sibling
# component cannot silently slip past the guard — add new entries explicitly.
# The sole phase-2 org-level component today is guardduty-delegated-admin
# (which owns aws_guardduty_organization_configuration — see
# components/terraform/guardduty-delegated-admin/main.tf).
_guardduty_org_components := {"guardduty-delegated-admin"}

# CT-managed account classes — stacks whose account_class is in this set are
# assumed to host state Control Tower already owns (CT-mgmt has the org root;
# audit is the delegated admin; log-archive hosts the CT org trail; aft-mgmt
# is the AFT-central control plane that sits on the CT-mgmt bus).
# See stacks/catalog/account-classes/ and docs/architecture/gha-design.md §4.6.1.
_ct_managed_classes := {
	"ct-mgmt",
	"aft-mgmt",
	"audit",
	"log-archive",
}

_is_ct_managed(stack) if {
	stack.vars.account_class in _ct_managed_classes
}

# GuardDuty organization-level components must not re-enable org-level GuardDuty
# if the stack is a CT-managed account class — CT already owns that state.
# `ct_managed` is inferred from the stack's account_class; callers never set
# `metadata.ct_managed` directly.
deny contains msg if {
	some stack_name, stack in input
	_is_ct_managed(stack)
	some comp_name, comp in stack.components.terraform
	_is_guardduty_org_component(comp)
	comp.vars.enable_organization_settings == true
	msg := sprintf(
		"stack %q component %q is on a CT-managed account class (%q) but sets enable_organization_settings=true — CT owns org-level GuardDuty state",
		[stack_name, comp_name, stack.vars.account_class],
	)
}

_is_guardduty_org_component(comp) if {
	src := _source(comp)
	src in _guardduty_org_components
}

_source(comp) := src if {
	src := comp.component
} else := src if {
	src := comp.metadata.component
} else := ""
