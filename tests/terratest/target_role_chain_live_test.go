//go:build e2e

package terratest_test

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/sts"
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
// Requires: TT_ENABLE_TAGS=e2e, AWS_* creds for the central role (what
// configure-aws would set), TT_LIVE_STACK + TT_LIVE_COMPONENT env vars
// naming a stack/component that resolves a target account.
func TestTargetRoleChain_LiveAssumeMatchesStack(t *testing.T) {
	helpers.RequireTag(t, "e2e")

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

	ctx := context.Background()

	cfg, err := config.LoadDefaultConfig(ctx)
	require.NoError(t, err, "aws config")

	stsCli := sts.NewFromConfig(cfg)

	// Verify the caller credentials reference the central deployment role
	// before we attempt the target hop. If we're running under the wrong
	// identity the downstream assertion would be misleading.
	centralIdent, err := stsCli.GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
	require.NoError(t, err, "sts:GetCallerIdentity for central credentials")
	require.NotNil(t, centralIdent.Arn)
	assert.Contains(t, *centralIdent.Arn, "AtmosCentralDeploymentRole",
		"caller ARN %q must reference AtmosCentralDeploymentRole — this test requires the central role as starting credentials", *centralIdent.Arn)

	assumeOut, err := stsCli.AssumeRole(ctx, &sts.AssumeRoleInput{
		RoleArn:         aws.String(roleArn),
		RoleSessionName: aws.String("atmos-aft-live-chain-probe"),
		DurationSeconds: aws.Int32(900),
	})
	require.NoError(t, err, "sts:AssumeRole into %s", roleArn)

	creds := assumeOut.Credentials
	require.NotNil(t, creds)

	probeCfg, err := config.LoadDefaultConfig(ctx,
		config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(
			*creds.AccessKeyId,
			*creds.SecretAccessKey,
			*creds.SessionToken,
		)),
	)
	require.NoError(t, err)

	ident, err := sts.NewFromConfig(probeCfg).GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
	require.NoError(t, err)
	require.NotNil(t, ident.Account)

	assert.Equal(t, expectedAccount, *ident.Account,
		"sts:GetCallerIdentity landed in %s but stack %s / component %s targets %s — the central→target chain is misrouted",
		*ident.Account, stack, component, expectedAccount)

	assert.True(t, strings.Contains(*ident.Arn, ":assumed-role/"+targetRole+"/"),
		"assumed identity ARN %q does not reference role %q", *ident.Arn, targetRole)
}
