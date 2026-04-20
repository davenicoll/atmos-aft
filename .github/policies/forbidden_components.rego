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

# Also block the raw Terraform resource types — catches components that
# inline the resource instead of calling the cloudposse module.
forbidden_resource_types := {
	"aws_organizations_organization",
	"aws_organizations_organizational_unit",
	"aws_organizations_account",
}

deny contains msg if {
	some stack_name, stack in input
	some comp_name, comp in stack.components.terraform
	some rt in _declared_resource_types(comp)
	forbidden_resource_types[rt]
	msg := sprintf(
		"stack %q component %q declares forbidden resource type %q",
		[stack_name, comp_name, rt],
	)
}

_component_source(comp) := src if {
	src := comp.component
} else := src if {
	src := comp.metadata.component
}

_declared_resource_types(comp) := types if {
	types := comp.metadata.resource_types
} else := []
