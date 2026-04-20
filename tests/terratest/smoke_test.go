package terratest_test

import (
	"os/exec"
	"strings"
	"testing"

	"github.com/davenicoll/atmos-aft/tests/terratest/helpers"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestSmokeAtmosBinary verifies the scaffold is wired up: we can locate the
// repo root, invoke the atmos CLI, and parse its version output. If this
// passes, tf-module-expert can start adding real component tests alongside
// helpers.DescribeComponent / helpers.TerraformOptionsForComponent.
func TestSmokeAtmosBinary(t *testing.T) {
	t.Parallel()
	root := helpers.RepoRoot(t)
	assert.NotEmpty(t, root, "repo root")

	out, err := exec.Command("atmos", "version").CombinedOutput()
	require.NoError(t, err, "atmos version: %s", string(out))
	assert.True(t, strings.Contains(string(out), "atmos"), "version output mentions atmos: %s", string(out))
}

// TestSmokeAtmosValidate exercises the `atmos validate stacks` path. Depends on
// task #17 landing the stack catalog — guarded so it skips cleanly when the
// catalog hasn't landed yet.
func TestSmokeAtmosValidate(t *testing.T) {
	t.Parallel()
	root := helpers.RepoRoot(t)
	out, err := exec.Command("atmos", "list", "stacks").CombinedOutput()
	if err != nil || len(strings.TrimSpace(string(out))) == 0 {
		t.Skipf("no stacks present yet (task #17 still pending); skipping validate smoke: %s", string(out))
	}
	helpers.AtmosValidate(t)
	_ = root
}
