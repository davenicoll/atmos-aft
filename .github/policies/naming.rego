# Atmos stack names must match `{tenant}-{environment}-{stage}` per atmos.yaml
# `stacks.name_pattern`. Enforcing this here prevents catalog drift that would
# otherwise only surface as opaque "stack not found" errors during apply.
#
# Segment grammar:
#   tenant      = core | plat | <letters-digits>   (routing cohort, single kebab-free token)
#   environment = gbl | use1 | euw1 | ...          (region short code or "gbl")
#   stage       = prod | staging | dev | sandbox | tools | security | log-archive | audit | ...
#
# Stage is the only segment that may contain hyphens — upstream account names
# like `log-archive` would otherwise force either stack/account drift or a
# renaming of the account class. Keeping stage kebab-capable means the stack
# name matches the account name (see stacks/orgs/**/log-archive/gbl.yaml).
package atmos.naming

import rego.v1

# Simple (hyphen-free) segment — used for tenant and environment.
segment_pattern := `[a-z][a-z0-9]*`

# Kebab-capable segment — used for stage only, so account-class names like
# `log-archive` survive as a single stage token. Non-capturing group keeps
# regex.match semantics aligned with the simple pattern.
kebab_segment_pattern := `[a-z][a-z0-9]*(?:-[a-z0-9]+)*`

# Full stack name: tenant-environment-stage. Only stage may be kebab-case.
stack_name_pattern := sprintf("^%s-%s-%s$", [segment_pattern, segment_pattern, kebab_segment_pattern])

# Allowed stage values — keeps the stage segment from drifting into ad-hoc names.
allowed_stages := {
	"prod",
	"staging",
	"dev",
	"sandbox",
	"tools",
	"security",
	"log-archive",
	"audit",
	"shared",
	"mgmt",
}

# Extract the stage segment: everything after the first two hyphens. `split`
# would break `log-archive` into two parts, so slice+join is required.
stage_of(stack_name) := stage if {
	parts := split(stack_name, "-")
	stage := concat("-", array.slice(parts, 2, count(parts)))
}

deny contains msg if {
	some stack_name, _ in input
	not regex.match(stack_name_pattern, stack_name)
	msg := sprintf(
		"stack name %q does not match pattern {tenant}-{environment}-{stage} (lowercase, alphanumeric, 3 segments; stage may be kebab-case)",
		[stack_name],
	)
}

deny contains msg if {
	some stack_name, _ in input
	regex.match(stack_name_pattern, stack_name)
	stage := stage_of(stack_name)
	not allowed_stages[stage]
	msg := sprintf(
		"stack name %q has unknown stage %q — add to allowed_stages in naming.rego or rename",
		[stack_name, stage],
	)
}
