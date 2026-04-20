package terratest_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestGuardDuty_ThreePhasesSeparated enforces the design-level split from
// module-inventory.md §5.5: the three GuardDuty components must NOT share
// resources that belong in a different phase. A phase-3 component that
// sets org-wide config would re-apply in every member account and fight
// the delegated admin for ownership.
func TestGuardDuty_ThreePhasesSeparated(t *testing.T) {
	t.Parallel()

	root := readComponent(t, "guardduty-root", "main.tf")
	deleg := readComponent(t, "guardduty-delegated-admin", "main.tf")
	member := readComponent(t, "guardduty-member-settings", "main.tf")

	// Phase 1 (root): admin-account registration only.
	assert.Contains(t, root, "aws_guardduty_organization_admin_account",
		"phase 1 must register the delegated admin")
	assert.NotContains(t, root, "aws_guardduty_organization_configuration",
		"org-level config belongs in phase 2, not phase 1")

	// Phase 2 (delegated admin): org-level config + detector features.
	assert.Contains(t, deleg, "auto_enable_organization_members",
		"phase 2 must configure auto-enable for org members")

	// Phase 3 (member): no org-wide resources.
	assert.NotContains(t, member, "aws_guardduty_organization_admin_account",
		"phase 3 must not try to register a delegated admin")
	assert.Contains(t, member, `"NONE"`,
		"member phase must pass auto_enable_organization_members=NONE")
}
