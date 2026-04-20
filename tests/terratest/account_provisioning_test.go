package terratest_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestAccountProvisioning_PreventDestroyAndIgnores asserts the two lifecycle
// rules that separate "we stop caring about this account on destroy" from
// "we delete the account on destroy" (the latter is never what we want).
func TestAccountProvisioning_PreventDestroyAndIgnores(t *testing.T) {
	t.Parallel()
	main := readComponent(t, "account-provisioning", "main.tf")

	assert.Contains(t, main, "prevent_destroy = true",
		"destroying a provisioned product terminates the AWS account — must be prevented")
	assert.Contains(t, main, "ignore_changes",
		"Service Catalog noisy tags cause perpetual diffs without ignore_changes")
}

// TestAccountProvisioning_ServiceCatalogResource checks we actually use the
// aws_servicecatalog_provisioned_product resource from §0.1 / row 27 — not
// the forbidden cloudposse/terraform-aws-account module.
func TestAccountProvisioning_ServiceCatalogResource(t *testing.T) {
	t.Parallel()
	main := readComponent(t, "account-provisioning", "main.tf")

	assert.Contains(t, main, "aws_servicecatalog_provisioned_product",
		"must wrap Service Catalog, not the forbidden cloudposse/terraform-aws-account module")
	assert.NotContains(t, main, "cloudposse/account/aws",
		"forbidden module detected — see module-inventory §0.1")
}

// TestAccountProvisioning_AccountIDOutput ensures the critical account_id
// output is exposed (downstream stacks read this via remote-state).
func TestAccountProvisioning_AccountIDOutput(t *testing.T) {
	t.Parallel()
	outs := readComponent(t, "account-provisioning", "outputs.tf")
	assert.Contains(t, outs, `"account_id"`,
		"account_id output is the primary remote-state contract")
}
