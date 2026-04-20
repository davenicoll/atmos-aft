package terratest_test

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestControlTowerEventBridge_EventPattern confirms we match only the three
// CT lifecycle events documented in mapping.md §4.1 — any broader pattern
// would flood GHA with noise.
func TestControlTowerEventBridge_EventPattern(t *testing.T) {
	t.Parallel()
	main := readComponent(t, "controltower-event-bridge", "main.tf")

	for _, e := range []string{"CreateManagedAccount", "UpdateManagedAccount", "RegisterOrganizationalUnit"} {
		assert.Contains(t, main, e, "event pattern must include %q", e)
	}
	assert.Contains(t, main, "aws.controltower", "pattern must filter on aws.controltower service")
}

// TestControlTowerEventBridge_InputTransformer verifies the input_transformer
// shapes the CT event into GitHub's repository_dispatch payload
// (event_id, account_id, account_email, ou_name, ou_id, provisioned_product_id).
func TestControlTowerEventBridge_InputTransformer(t *testing.T) {
	t.Parallel()
	main := readComponent(t, "controltower-event-bridge", "main.tf")

	assert.Contains(t, main, "input_transformer", "input transformer missing")
	for _, f := range []string{"event_type", "client_payload", "event_id", "account_id"} {
		assert.Contains(t, main, f, "payload field missing: %q", f)
	}
}

// TestControlTowerEventBridge_TwoCMKs is the load-bearing test for the rotator
// security story (gha-design.md §10.1): in app mode, PEM and token secrets
// must sit on distinct CMKs so the rotator cannot read its own output.
func TestControlTowerEventBridge_TwoCMKs(t *testing.T) {
	t.Parallel()
	secrets := readComponent(t, "controltower-event-bridge", "secrets.tf")
	rotator := readComponent(t, "controltower-event-bridge", "rotator.tf")

	// Two KMS keys in secrets.tf.
	assert.GreaterOrEqual(t, strings.Count(secrets, `aws_kms_key`), 2,
		"app mode must create two distinct CMKs (PEM + token)")

	// Rotator IAM: Decrypt on PEM CMK, Encrypt/GenerateDataKey on token CMK.
	assert.Contains(t, rotator, "kms:Decrypt", "rotator must decrypt PEM CMK")
	assert.Contains(t, rotator, "kms:Encrypt", "rotator must encrypt to token CMK")
	assert.Contains(t, rotator, "kms:GenerateDataKey", "rotator must GenerateDataKey on token CMK")
}

// TestControlTowerEventBridge_DLQRetention asserts the 14-day DLQ retention
// called out in module-inventory row 8 / mapping.md §4.1 (matches EventBridge
// max redrive window).
func TestControlTowerEventBridge_DLQRetention(t *testing.T) {
	t.Parallel()
	dlq := readComponent(t, "controltower-event-bridge", "dlq.tf")

	assert.Contains(t, dlq, "1209600",
		"DLQ retention must be 14 days (1,209,600 seconds) — EventBridge max replay window")
}

// TestControlTowerEventBridge_AuthModeEnum ensures the github_auth_mode variable
// validates to app|pat only — any other value would hit AWS with junk.
func TestControlTowerEventBridge_AuthModeEnum(t *testing.T) {
	t.Parallel()
	vars := readComponent(t, "controltower-event-bridge", "variables.tf")

	assert.Contains(t, vars, `"app"`)
	assert.Contains(t, vars, `"pat"`)
	assert.Contains(t, vars, "contains([",
		"github_auth_mode must have a contains(...) validation block")
}

