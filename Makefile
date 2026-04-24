.DEFAULT_GOAL := help

SHELL        := /usr/bin/env bash
.SHELLFLAGS  := -euo pipefail -c

ATMOS        ?= atmos
OPA          ?= opa
CONFTEST     ?= conftest
TERRAFORM    ?= terraform
TFLINT       ?= tflint
ACT          ?= act
GO           ?= go
TERRATEST    ?= $(GO) test -v -timeout 90m

STACKS_DIR   := stacks
POLICY_DIR   := .github/policies
OPA_TESTS    := tests/opa
TF_TESTS     := tests/terratest
ACT_TESTS    := tests/act
COMPONENTS   := components/terraform

# Optional; set TT_TAGS=e2e to include e2e-tagged Terratest suites.
TT_TAGS      ?=

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} \
		/^[a-zA-Z0-9_.-]+:.*?##/ { printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# --- Static tier -----------------------------------------------------------

.PHONY: atmos-validate
atmos-validate: ## Validate every stack (schema + component refs)
	$(ATMOS) validate stacks

.PHONY: atmos-describe
atmos-describe: ## Emit a resolved view of all stacks as JSON
	$(ATMOS) describe stacks --format json > /dev/null

.PHONY: atmos-affected
atmos-affected: ## Print stacks/components changed vs origin/main
	$(ATMOS) describe affected --ref origin/main --format json

.PHONY: tf-fmt
tf-fmt: ## Check Terraform formatting (CI mode — no writes)
	$(TERRAFORM) fmt -check -recursive $(COMPONENTS)

.PHONY: tf-fmt-fix
tf-fmt-fix: ## Format Terraform in-place
	$(TERRAFORM) fmt -recursive $(COMPONENTS)

.PHONY: tf-validate
tf-validate: ## terraform init -backend=false + validate every component
	@for dir in $$(find $(COMPONENTS) -type f -name '*.tf' -exec dirname {} \; | sort -u); do \
		echo "==> $$dir"; \
		(cd "$$dir" && $(TERRAFORM) init -backend=false -input=false > /dev/null && $(TERRAFORM) validate); \
	done

.PHONY: tflint
tflint: ## Run tflint across every component
	@for dir in $$(find $(COMPONENTS) -type f -name '*.tf' -exec dirname {} \; | sort -u); do \
		echo "==> $$dir"; \
		(cd "$$dir" && $(TFLINT) --minimum-failure-severity=warning); \
	done

.PHONY: tf-test
tf-test: ## Run `terraform test` in every component that has a tests/ subdir
	@for dir in $$(find $(COMPONENTS) -type d -name tests -not -path '*/.terraform/*' -not -path '*/modules/*' | sort); do \
		component=$$(dirname "$$dir"); \
		echo "==> $$component"; \
		(cd "$$component" && $(TERRAFORM) init -backend=false -input=false > /dev/null && $(TERRAFORM) test); \
	done

.PHONY: test-static
test-static: atmos-validate atmos-describe tf-fmt tf-validate tflint tf-test ## Static tier: atmos + fmt + validate + tflint + tf-test

# --- OPA tier --------------------------------------------------------------

.PHONY: opa-test
opa-test: ## Run OPA/Rego unit tests under tests/opa
	$(OPA) test $(POLICY_DIR) $(OPA_TESTS) -v

.PHONY: opa-fmt
opa-fmt: ## Format Rego policies in-place
	$(OPA) fmt --write $(POLICY_DIR) $(OPA_TESTS)

.PHONY: conftest
conftest: ## Run conftest against all stacks using .github/policies
	$(ATMOS) describe stacks --format json \
		| $(CONFTEST) test --policy $(POLICY_DIR) --all-namespaces -

.PHONY: test-opa
test-opa: opa-test conftest ## OPA tier: policy unit tests + conftest against stacks

# --- act tier --------------------------------------------------------------

.PHONY: test-act
test-act: ## Dry-run GHA workflows locally via act
	cd $(ACT_TESTS) && $(ACT) -W ../../.github/workflows --dryrun

# --- Terratest tier --------------------------------------------------------

.PHONY: test-terratest
test-terratest: ## Run Terratest suite (TT_TAGS=e2e for live-AWS suites)
	cd $(TF_TESTS) && TT_ENABLE_TAGS=$(TT_TAGS) $(TERRATEST) -tags="$(TT_TAGS)" ./...

# --- Aggregate -------------------------------------------------------------

.PHONY: test-all
test-all: test-static test-opa test-act test-terratest ## Run every tier

.PHONY: lint
lint: test-static test-opa ## Fast static checks (static + opa; no act/terratest)

.PHONY: vendor-pull
vendor-pull: ## Refresh vendored components per vendor.yaml
	$(ATMOS) vendor pull
