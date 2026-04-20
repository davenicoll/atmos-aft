// Package helpers wraps the Atmos CLI + Terratest for component tests.
package helpers

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/require"
)

// RepoRoot returns the repo root, located by walking up from this file until a
// directory containing atmos.yaml is found.
func RepoRoot(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	require.True(t, ok, "cannot determine caller")
	dir := filepath.Dir(file)
	for i := 0; i < 10; i++ {
		if _, err := exec.Command("test", "-f", filepath.Join(dir, "atmos.yaml")).CombinedOutput(); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	t.Fatalf("could not locate atmos.yaml walking up from %s", filepath.Dir(file))
	return ""
}

// DescribeComponent returns the resolved component config for (component, stack)
// as an untyped map, parsed from `atmos describe component`.
func DescribeComponent(t *testing.T, component, stack string) map[string]any {
	t.Helper()
	root := RepoRoot(t)
	cmd := exec.Command("atmos", "describe", "component", component, "-s", stack, "--format", "json")
	cmd.Dir = root
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, "atmos describe component failed: %s", string(out))
	var parsed map[string]any
	require.NoError(t, json.Unmarshal(out, &parsed), "unmarshal atmos output")
	return parsed
}

// ComponentPath returns the absolute path to a component's Terraform module.
func ComponentPath(t *testing.T, component string) string {
	t.Helper()
	return filepath.Join(RepoRoot(t), "components", "terraform", component)
}

// TerraformOptionsForComponent builds a Terratest options struct pointed at the
// component's source directory, with atmos-resolved vars pre-populated. Callers
// typically overlay test-specific vars on top of the returned map.
func TerraformOptionsForComponent(t *testing.T, component, stack string, extraVars map[string]any) *terraform.Options {
	t.Helper()
	desc := DescribeComponent(t, component, stack)
	vars, _ := desc["vars"].(map[string]any)
	if vars == nil {
		vars = map[string]any{}
	}
	for k, v := range extraVars {
		vars[k] = v
	}
	opts := &terraform.Options{
		TerraformDir: ComponentPath(t, component),
		Vars:         vars,
		NoColor:      true,
	}
	return opts
}

// AtmosValidate runs `atmos validate stacks` — useful as a prereq in tests that
// depend on stack config being well-formed.
func AtmosValidate(t *testing.T) {
	t.Helper()
	cmd := exec.Command("atmos", "validate", "stacks")
	cmd.Dir = RepoRoot(t)
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, "atmos validate stacks: %s", string(out))
}

// RequireTag marks a test as requiring a go build tag. Call at the top of a
// test to skip it when the tag is not set. Used by e2e tests to gate on live
// AWS credentials.
func RequireTag(t *testing.T, tag string) {
	t.Helper()
	// Build-tag gating happens at compile time via //go:build lines. This
	// function exists as a readable hint inside test bodies and also checks
	// an env var so a human can run a single test without rebuilding.
	if v := getenv("TT_ENABLE_TAGS"); v != "" {
		for _, t := range strings.Split(v, ",") {
			if strings.TrimSpace(t) == tag {
				return
			}
		}
	}
	t.Skipf("skipping: requires build tag %q (set TT_ENABLE_TAGS=%s to force)", tag, tag)
}

func getenv(k string) string {
	out, err := exec.Command("sh", "-c", fmt.Sprintf("printf %%s \"$%s\"", k)).Output()
	if err != nil {
		return ""
	}
	return string(out)
}
