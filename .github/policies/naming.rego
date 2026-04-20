# Atmos stack names must match `{tenant}-{environment}-{stage}` per atmos.yaml
# `stacks.name_pattern`. Enforcing this here prevents catalog drift that would
# otherwise only surface as opaque "stack not found" errors during apply.
#
# Segment grammar:
#   tenant      = core | plat | <letters-digits>   (routing cohort)
#   environment = gbl | use1 | euw1 | ...          (region short code or "gbl")
#   stage       = prod | staging | dev | sandbox | tools | security | log | audit
package atmos.naming

import rego.v1

# Component of the pattern (one segment).
segment_pattern := `[a-z][a-z0-9]*`

# Full stack name: three segments joined by `-`.
stack_name_pattern := sprintf("^%s-%s-%s$", [segment_pattern, segment_pattern, segment_pattern])

# Allowed stage values — keeps the stage segment from drifting into ad-hoc names.
allowed_stages := {
	"prod",
	"staging",
	"dev",
	"sandbox",
	"tools",
	"security",
	"log",
	"audit",
	"shared",
	"mgmt",
}

deny contains msg if {
	some stack_name, _ in input
	not regex.match(stack_name_pattern, stack_name)
	msg := sprintf(
		"stack name %q does not match pattern {tenant}-{environment}-{stage} (lowercase, alphanumeric, 3 segments)",
		[stack_name],
	)
}

deny contains msg if {
	some stack_name, _ in input
	regex.match(stack_name_pattern, stack_name)
	parts := split(stack_name, "-")
	stage := parts[2]
	not allowed_stages[stage]
	msg := sprintf(
		"stack name %q has unknown stage %q — add to allowed_stages in naming.rego or rename",
		[stack_name, stage],
	)
}
