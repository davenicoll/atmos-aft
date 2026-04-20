package terratest_test

import (
	"os"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sts"
	"github.com/davenicoll/atmos-aft/tests/terratest/helpers"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestTargetRoleChain_LiveAssumeMatchesStack closes the architect's #25
// exit criterion: assume `target_role_arn` against live AWS and assert
// sts:GetCallerIdentity returns the account_id that `atmos describe
// component` says the stack targets. Proves the central→target hop
// actually lands in the right account.
//
// Requires: TT_ENABLE_TAGS=live, AWS_* creds for the central role (what
// configure-aws would set), TT_LIVE_STACK + TT_LIVE_COMPONENT env vars
// naming a stack/component that resolves a target account.
func TestTargetRoleChain_LiveAssumeMatchesStack(t *testing.T) {
	helpers.RequireTag(t, "live")

	stack := os.Getenv("TT_LIVE_STACK")
	component := os.Getenv("TT_LIVE_COMPONENT")
	if stack == "" || component == "" {
		t.Skip("set TT_LIVE_STACK and TT_LIVE_COMPONENT to enable this test")
	}

	desc := helpers.DescribeComponent(t, component, stack)
	vars, _ := desc["vars"].(map[string]any)
	require.NotNil(t, vars, "describe component returned no vars")

	expectedAccount, _ := vars["account_id"].(string)
	require.NotEmpty(t, expectedAccount, "vars.account_id missing — this stack is central-only and has no target hop to verify")

	targetRole, _ := vars["bootstrap_role"].(string)
	if targetRole == "" {
		targetRole = "AtmosDeploymentRole"
	}
	roleArn := "arn:aws:iam::" + expectedAccount + ":role/" + targetRole

	sess, err := session.NewSession()
	require.NoError(t, err, "aws session")

	stsCli := sts.New(sess)
	assumeOut, err := stsCli.AssumeRole(&sts.AssumeRoleInput{
		RoleArn:         aws.String(roleArn),
		RoleSessionName: aws.String("atmos-aft-live-chain-probe"),
		DurationSeconds: aws.Int64(900),
	})
	require.NoError(t, err, "sts:AssumeRole into %s", roleArn)

	creds := assumeOut.Credentials
	require.NotNil(t, creds)

	probeSess, err := session.NewSession(&aws.Config{
		Credentials: credentials.NewStaticCredentials(
			*creds.AccessKeyId,
			*creds.SecretAccessKey,
			*creds.SessionToken,
		),
	})
	require.NoError(t, err)

	ident, err := sts.New(probeSess).GetCallerIdentity(&sts.GetCallerIdentityInput{})
	require.NoError(t, err)
	require.NotNil(t, ident.Account)

	assert.Equal(t, expectedAccount, *ident.Account,
		"sts:GetCallerIdentity landed in %s but stack %s / component %s targets %s — the central→target chain is misrouted",
		*ident.Account, stack, component, expectedAccount)

	assert.True(t, strings.Contains(*ident.Arn, ":assumed-role/"+targetRole+"/"),
		"assumed identity ARN %q does not reference role %q", *ident.Arn, targetRole)
}
