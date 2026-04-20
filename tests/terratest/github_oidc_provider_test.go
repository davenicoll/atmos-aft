package terratest_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestGithubOIDCProvider_IssuerAndAudience asserts the GitHub-specific
// issuer host and the AWS STS audience — both have no-default-sane
// values and are frequently mis-copied from other providers.
func TestGithubOIDCProvider_IssuerAndAudience(t *testing.T) {
	t.Parallel()
	main := readComponent(t, "github-oidc-provider", "main.tf")
	vars := readComponent(t, "github-oidc-provider", "variables.tf")

	assert.Contains(t, vars, "token.actions.githubusercontent.com",
		"GitHub's OIDC issuer host must be the default")
	assert.Contains(t, vars, "sts.amazonaws.com",
		"STS must be in the client_id_list default")
	assert.Contains(t, main, "data \"tls_certificate\"",
		"thumbprint must auto-pin from a runtime cert fetch, not be hardcoded")
}
