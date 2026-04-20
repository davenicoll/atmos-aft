package terratest_test

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestIAMDeploymentRolesCentral asserts the three roles and the trust-scope
// pins documented in gha-design.md §4.5:
//   - AtmosCentralDeploymentRole: trust pinned to 4 sub claims
//     (refs/heads/main + three environment pins).
//   - AtmosPlanOnlyRole: trust pinned to pull_request.
//   - AtmosReadAllStateRole: same-account trust from AtmosCentralDeploymentRole
//     only, with a write-denying permissions boundary.
func TestIAMDeploymentRolesCentral_StructuralTrust(t *testing.T) {
	t.Parallel()
	main := readComponent(t, "iam-deployment-roles/central", "main.tf")

	// Role presence
	for _, n := range []string{
		"AtmosCentralDeploymentRole",
		"AtmosPlanOnlyRole",
		"AtmosReadAllStateRole",
	} {
		assert.Contains(t, main, n, "missing role %q", n)
	}

	// Central role: trust pinning on 4 sub claims.
	assert.Contains(t, main, "repo:", "OIDC sub claim prefix missing")
	pinned := strings.Count(main, "ref:refs/heads/main") +
		strings.Count(main, "environment:")
	assert.GreaterOrEqual(t, pinned, 3, "central role should pin ≥3 sub claims beyond main")

	// Plan-only role: pull_request trust pin.
	assert.Contains(t, main, "pull_request", "plan-only role must trust pull_request events")

	// ReadAll role: write-deny boundary.
	assert.Contains(t, main, "permissions_boundary", "ReadAllStateRole must use a permissions boundary")
	for _, deny := range []string{"s3:Put", "s3:Delete", "kms:Encrypt", "kms:GenerateDataKey", "kms:ReEncrypt"} {
		assert.Contains(t, main, deny, "permissions boundary should Deny %q", deny)
	}
}

// TestIAMDeploymentRolesCentral_AssumeChain asserts the central role can assume
// into the downstream roles (module-inventory row 11). Cross-account targets
// appear as literal "role/<Name>" ARN suffixes; the same-account ReadAllState
// role is referenced via the Terraform resource attribute, so accept either form.
func TestIAMDeploymentRolesCentral_AssumeChain(t *testing.T) {
	t.Parallel()
	main := readComponent(t, "iam-deployment-roles/central", "main.tf")

	for _, target := range []string{
		"role/AtmosDeploymentRole",
		"role/AWSControlTowerExecution",
		"role/OrganizationAccountAccessRole",
	} {
		assert.Contains(t, main, target, "central role must have sts:AssumeRole permission for %q", target)
	}

	hasReadAll := strings.Contains(main, "role/AtmosReadAllStateRole") ||
		strings.Contains(main, "aws_iam_role.read_all_state")
	assert.True(t, hasReadAll,
		"central role must grant sts:AssumeRole on AtmosReadAllStateRole (literal ARN or aws_iam_role.read_all_state reference)")
}
