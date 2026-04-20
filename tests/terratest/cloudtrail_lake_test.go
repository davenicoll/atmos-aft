package terratest_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestCloudTrailLake_RetentionAndProtection asserts the two non-negotiable
// compliance knobs from mapping.md §4.1 (replaces aft-request-audit):
//   - 7-year default retention (2,557 days) — required for 7y audit replay.
//   - Termination protection enabled — the store is the primary audit
//     surface, an accidental destroy loses history irrecoverably.
func TestCloudTrailLake_RetentionAndProtection(t *testing.T) {
	t.Parallel()
	main := readComponent(t, "cloudtrail-lake", "main.tf")

	assert.Contains(t, main, "aws_cloudtrail_event_data_store",
		"component must use event_data_store (the CT-Lake resource), not a classic trail")
	assert.Contains(t, main, "termination_protection_enabled = true",
		"termination protection is mandatory for the audit store")
}

// TestCloudTrailLake_Retention validates the retention defaults to 7 years.
func TestCloudTrailLake_Retention(t *testing.T) {
	t.Parallel()
	vars := readComponent(t, "cloudtrail-lake", "variables.tf")
	// default is 2557 days (7y); allow up to 3653 (10y).
	assert.Contains(t, vars, "2557", "default retention must be 7 years (2,557 days)")
}

// TestCloudTrailLake_AdvancedSelector ensures we filter to the 4 relevant
// services — not every AWS API call — to keep store cost predictable.
func TestCloudTrailLake_AdvancedSelector(t *testing.T) {
	t.Parallel()
	main := readComponent(t, "cloudtrail-lake", "main.tf")
	for _, svc := range []string{"controltower", "organizations", "servicecatalog", "sts"} {
		assert.Contains(t, main, svc+".amazonaws.com",
			"advanced event selector must include %q", svc)
	}
}
