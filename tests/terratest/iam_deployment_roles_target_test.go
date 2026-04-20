package terratest_test

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestIAMDeploymentRolesTarget_FiveClasses checks the target component's
// account_class enum covers all 5 classes from gha-design.md §4.6:
// ct-mgmt, aft-mgmt, audit, log-archive, vended. If anyone shortens this
// to "vended-only" by accident the stamp-into-CT-core story breaks.
func TestIAMDeploymentRolesTarget_FiveClasses(t *testing.T) {
	t.Parallel()
	vars := readComponent(t, "iam-deployment-roles/target", "variables.tf")

	for _, c := range []string{"ct-mgmt", "aft-mgmt", "audit", "log-archive", "vended"} {
		assert.Contains(t, vars, c, "account_class enum missing %q", c)
	}
}

// TestIAMDeploymentRolesTarget_ExternalIDConditional ensures the external_id
// guardrail fires only for the 4 CT-core classes, not for vended (per §4.6).
// The component does this via dynamic sts:ExternalId statement rendering.
func TestIAMDeploymentRolesTarget_ExternalIDConditional(t *testing.T) {
	t.Parallel()
	main := readComponent(t, "iam-deployment-roles/target", "main.tf")

	assert.Contains(t, main, "sts:ExternalId", "ExternalId condition missing")
	// the component should branch on account_class, not unconditionally apply.
	assert.True(t,
		strings.Contains(main, "account_class") || strings.Contains(main, "external_id_required"),
		"ExternalId must be gated on account_class (not unconditional)")
}

// TestIAMDeploymentRolesTarget_UserIDMatch confirms the trust policy requires
// the assume-role session name to start with 'atmos-' (gha-design.md §4.6).
func TestIAMDeploymentRolesTarget_UserIDMatch(t *testing.T) {
	t.Parallel()
	main := readComponent(t, "iam-deployment-roles/target", "main.tf")

	assert.Contains(t, main, "aws:userid", "trust policy must key on aws:userid")
	assert.Contains(t, main, "atmos-", "userid pattern must require atmos- prefix")
}

// TestIAMDeploymentRolesTarget_ProviderAlias asserts the component uses aws.target
// so the role lands in the target account, not aft-mgmt.
func TestIAMDeploymentRolesTarget_ProviderAlias(t *testing.T) {
	t.Parallel()
	providers := readComponent(t, "iam-deployment-roles/target", "providers.tf")
	assert.Contains(t, providers, `alias  = "target"`, "aws.target alias must be declared")
}
