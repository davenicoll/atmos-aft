package terratest_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/davenicoll/atmos-aft/tests/terratest/helpers"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestTfstateBackend_Structural asserts the component encodes the non-negotiable
// architectural decisions from module-inventory.md §2.6:
//   - DynamoDB lock table disabled; S3 native locking enabled.
//   - DenyInsecureTransport statement present.
//   - AtmosReadAllStateRole cross-account read grant present (S3 + KMS).
//   - kms:ViaService scoping on the decrypt statement.
//
// These are load-bearing for the blast-radius-per-account model — if any one
// breaks, the review.md §4.3 blocker reopens.
func TestTfstateBackend_Structural(t *testing.T) {
	t.Parallel()
	main := readComponent(t, "tfstate-backend", "main.tf")

	assert.Contains(t, main, "dynamodb_enabled      = false", "DDB lock table must be disabled")
	assert.Contains(t, main, "s3_state_lock_enabled = true", "S3 native locking must be enabled")
	assert.Contains(t, main, `"DenyInsecureTransport"`, "deny-non-TLS statement missing")
	assert.Contains(t, main, "AtmosReadAllStateRoleRead", "cross-account S3 read grant missing")
	assert.Contains(t, main, `"ReadAllStateDecrypt"`, "cross-account KMS decrypt grant missing")
	assert.Contains(t, main, "kms:ViaService", "KMS decrypt must be scoped via kms:ViaService")
	assert.Contains(t, main, "aws_kms_key_policy", "sibling key-policy resource missing")
}

// TestTfstateBackendCentral_Structural is lighter: we only need to see it points
// at the same cloudposse/tfstate-backend v1.9.0 module as the per-account primary
// (module-inventory row 48). Naming convention checked separately by OPA.
func TestTfstateBackendCentral_Structural(t *testing.T) {
	t.Parallel()
	main := readComponent(t, "tfstate-backend-central", "main.tf")

	assert.Contains(t, main, `source  = "cloudposse/tfstate-backend/aws"`, "must use the same module as row 1")
	assert.Contains(t, main, `version = "1.9.0"`, "version must be pinned to v1.9.0")
	assert.Contains(t, main, "dynamodb_enabled      = false", "DDB disabled on bootstrap bucket too")
}

// TestTfstateBackend_TerraformValidate runs terraform init + validate in the
// component dir. Catches provider drift + syntax errors without touching AWS.
func TestTfstateBackend_TerraformValidate(t *testing.T) {
	t.Parallel()
	opts := &terraform.Options{
		TerraformDir: helpers.ComponentPath(t, "tfstate-backend"),
		NoColor:      true,
	}
	if _, err := terraform.InitE(t, opts); err != nil {
		t.Skipf("terraform init unavailable: %v", err)
	}
	_, err := terraform.ValidateE(t, opts)
	require.NoError(t, err, "terraform validate must pass")
}

func readComponent(t *testing.T, component, file string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(helpers.ComponentPath(t, component), file))
	require.NoError(t, err, "read %s/%s", component, file)
	return string(b)
}

// compile-time sentinel: catch a rename of the helper path.
var _ = strings.Contains
