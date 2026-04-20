# The `aws.target` alias is the one that stamps AtmosDeploymentRole + the
# ReadOnly variant into the target account. It assumes var.target_role_arn
# which the configure-aws composite action wires via TF_VAR_target_role_arn.
# During bootstrap the caller sets target_role_arn to OAAR or
# AWSControlTowerExecution; post-bootstrap runs route through whichever role
# was already stamped.

provider "aws" {
  region = var.region
}

provider "aws" {
  alias  = "target"
  region = var.region

  dynamic "assume_role" {
    for_each = var.target_role_arn != "" ? [1] : []
    content {
      role_arn     = var.target_role_arn
      session_name = "atmos-aft-bootstrap"
    }
  }
}
