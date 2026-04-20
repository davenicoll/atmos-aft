module "budgets" {
  source  = "cloudposse/budgets/aws"
  version = "0.8.0"

  budgets = var.budgets

  context = module.this.context
}
