package terratest_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/davenicoll/atmos-aft/tests/terratest/helpers"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestTargetRoleChain_ProvidersHaveDynamicAssumeRole guards task #26: every
// component's providers.tf must wire the dynamic assume_role block that lets
// the GHA composite flip Terraform into the target account via
// TF_VAR_target_role_arn. If a new component is added without this, PR plan
// / drift / deploy silently run under central-role creds.
func TestTargetRoleChain_ProvidersHaveDynamicAssumeRole(t *testing.T) {
	t.Parallel()
	root := helpers.RepoRoot(t)
	base := filepath.Join(root, "components", "terraform")

	var providers []string
	require.NoError(t, filepath.Walk(base, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			if info.Name() == ".terraform" {
				return filepath.SkipDir
			}
			return nil
		}
		if filepath.Base(p) == "providers.tf" {
			providers = append(providers, p)
		}
		return nil
	}))
	require.NotEmpty(t, providers, "expected at least one providers.tf under components/terraform")

	for _, p := range providers {
		b, err := os.ReadFile(p)
		require.NoError(t, err, p)
		body := string(b)
		rel, _ := filepath.Rel(root, p)
		assert.Contains(t, body, `dynamic "assume_role"`,
			"%s missing dynamic assume_role block (see #26)", rel)
		assert.Contains(t, body, "var.target_role_arn",
			"%s missing var.target_role_arn reference (see #26)", rel)
	}
}

// TestTargetRoleChain_VariablesDeclareTargetRoleArn ensures every component
// whose providers.tf references var.target_role_arn also declares the
// variable in variables.tf. Prevents a partial-commit footgun.
func TestTargetRoleChain_VariablesDeclareTargetRoleArn(t *testing.T) {
	t.Parallel()
	root := helpers.RepoRoot(t)
	base := filepath.Join(root, "components", "terraform")

	var varFiles []string
	require.NoError(t, filepath.Walk(base, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			if info.Name() == ".terraform" {
				return filepath.SkipDir
			}
			return nil
		}
		// Only root-level variables.tf (sibling of providers.tf), not nested
		// modules under modules/ / examples/.
		rel, _ := filepath.Rel(base, p)
		if strings.Contains(rel, string(os.PathSeparator)+"modules"+string(os.PathSeparator)) ||
			strings.Contains(rel, string(os.PathSeparator)+"examples"+string(os.PathSeparator)) {
			return nil
		}
		if filepath.Base(p) == "variables.tf" {
			varFiles = append(varFiles, p)
		}
		return nil
	}))
	require.NotEmpty(t, varFiles)

	for _, v := range varFiles {
		b, err := os.ReadFile(v)
		require.NoError(t, err, v)
		body := string(b)
		rel, _ := filepath.Rel(root, v)
		assert.True(t, strings.Contains(body, `variable "target_role_arn"`),
			"%s missing variable \"target_role_arn\" declaration (see #26)", rel)
	}
}

// TestTargetRoleChain_IAMDeploymentRolesTargetAliasPins confirms the
// aws.target alias in iam-deployment-roles/target stamps the dynamic
// assume_role that bootstrap.yaml / provision-account.yaml rely on to
// first create AtmosDeploymentRole in a freshly vended / CT-core account.
func TestTargetRoleChain_IAMDeploymentRolesTargetAliasPins(t *testing.T) {
	t.Parallel()
	body, err := os.ReadFile(filepath.Join(
		helpers.RepoRoot(t),
		"components", "terraform", "iam-deployment-roles", "target", "providers.tf",
	))
	require.NoError(t, err)
	s := string(body)
	assert.Contains(t, s, `alias  = "target"`, "aws.target alias must remain declared")
	// Make sure the alias block — not just the default provider — contains
	// the dynamic assume_role. The simplest structural check is that the
	// alias declaration appears before the dynamic block and that both are
	// present.
	aliasIdx := strings.Index(s, `alias  = "target"`)
	dynIdx := strings.LastIndex(s, `dynamic "assume_role"`)
	require.True(t, aliasIdx >= 0 && dynIdx >= 0)
	assert.Less(t, aliasIdx, dynIdx,
		"dynamic assume_role must live on (or after) the aws.target alias block, not only on the default provider")
}
