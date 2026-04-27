# ---------------------------------------------------------------------------
# CONTROL TOWER COEXISTENCE WARNING
# ---------------------------------------------------------------------------
# Wraps ONLY the conformance-pack submodule. On any CT-enrolled account Config
# is managed by CT - conformance packs must be deployed via the CT delegated
# admin (audit account), not by applying this component in-account.
#
# Enforcement is the `var.skip_on_ct_managed_account` flag combined with the
# OPA policies in .github/policies/ which deny this component on CT-managed
# stacks at PR time. See aws-config-rules/main.tf for the full rationale.
# ---------------------------------------------------------------------------

module "pack" {
  count = var.skip_on_ct_managed_account ? 0 : 1

  source  = "cloudposse/config/aws//modules/conformance-pack"
  version = "1.6.1"

  conformance_pack    = var.conformance_pack_url
  parameter_overrides = var.parameter_overrides

  context = module.this.context
}
