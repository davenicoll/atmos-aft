# Wraps ONLY the conformance-pack submodule. See aws-config-rules for the CT-compat rationale.

module "pack" {
  source  = "cloudposse/config/aws//modules/conformance-pack"
  version = "1.6.1"

  conformance_pack    = var.conformance_pack_url
  parameter_overrides = var.parameter_overrides

  context = module.this.context
}
