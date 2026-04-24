# Denies any component whose source module manages AWS Organizations, OU, or
# Account resources directly — Control Tower owns those, and re-declaring them
# in Atmos would drift CT state and can orphan the management account.
#
# Forbidden set is derived from docs/architecture/module-inventory.md §0.1.
# Input: `atmos describe stacks --format json` — map of stack_name -> stack_data.
package atmos.components

import rego.v1

forbidden_sources := {
	"aws-organization",
	"aws-organizational-unit",
	"aws-account",
}

deny contains msg if {
	some stack_name, stack in input
	some comp_name, comp in stack.components.terraform
	src := _component_source(comp)
	forbidden_sources[src]
	msg := sprintf(
		"stack %q component %q uses forbidden source %q (Control Tower owns Org/OU/Account resources — see module-inventory.md §0.1)",
		[stack_name, comp_name, src],
	)
}

_component_source(comp) := src if {
	src := comp.component
} else := src if {
	src := comp.metadata.component
}
