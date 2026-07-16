.PHONY: help lint template render verify env-config test all

CHART       ?= chart
ENV         ?= aks-test
VALUES      ?= $(CHART)/values-$(ENV).yaml
FOUNDATION  ?= ../plat-eng-aks-foundation/aks-foundation
RENDER_OUT  ?= render-out

# Default target
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

lint: ## helm lint the control-plane chart
	helm lint $(CHART) --values $(VALUES)

template: ## Render the chart to stdout
	@helm template control-plane $(CHART) --values $(VALUES)

## Validates the TOP-LEVEL objects against the CRDs actually installed in the cluster.
##
## Know its blind spot: the managed resources inside a Composition's `input.resources[].base`
## are opaque to the API server — this validates the Composition, not what the Composition
## would create. `make verify` closes that gap; run both.
##
## kubeconform is deliberately not used: it has no schemas for Crossplane types and reports
## every resource "Skipped", which reads like a pass while checking nothing.
test: ## Server-side dry-run the rendered manifests against the live CRDs (needs cluster access)
	@helm template control-plane $(CHART) --values $(VALUES) | \
		kubectl apply --dry-run=server -f -

## The check that actually catches a bad Composition.
##
## Neither `make test` nor `make render` can do this alone. `test` never sees inside a
## Composition's base; `render` never contacts a cluster, so it cannot know a CRD's schema and
## will happily emit a field that does not exist. Both blockers found in review (a nonexistent
## administratorPasswordSecretRef.namespace, and a nonexistent FlexibleServerDatabase
## forProvider.name) passed `test` AND `render` cleanly. Only dry-running the *rendered* output
## catches them.
##
## Resources are dry-run in `default` with namespace/ownerRefs stripped: the XR's real namespace
## need not exist, and nothing is created. Kinds whose provider is withheld (PrivateEndpoint,
## see values.yaml providers.network) are reported as skipped rather than failed.
XR_API := $(shell yq -r '.xrds.group' $(CHART)/values.yaml)/$(shell yq -r '.xrds.version' $(CHART)/values.yaml)

verify: render ## Dry-run the RENDERED managed resources against live CRDs — catches bad bases
	@rc=0; for f in $(RENDER_OUT)/*.rendered.yaml; do \
		name=$$(basename $$f .rendered.yaml); \
		echo "--- verify: $$name"; \
		yq ea 'select(.apiVersion != "$(XR_API)") | del(.metadata.namespace) | del(.metadata.ownerReferences) | del(.metadata.generateName)' \
			$$f > $(RENDER_OUT)/$$name.composed.yaml; \
		yq ea '.kind' $(RENDER_OUT)/$$name.composed.yaml | grep -vE '^(---|null)$$' | sort -u > $(RENDER_OUT)/$$name.kinds; \
		for kind in $$(cat $(RENDER_OUT)/$$name.kinds); do \
			yq ea "select(.kind == \"$$kind\")" $(RENDER_OUT)/$$name.composed.yaml > $(RENDER_OUT)/$$name.$$kind.yaml; \
			if out=$$(kubectl apply --dry-run=server -n default -f $(RENDER_OUT)/$$name.$$kind.yaml 2>&1); then \
				echo "      OK   $$kind"; \
			elif echo "$$out" | grep -q "no matches for kind"; then \
				echo "      SKIP $$kind (provider withheld — see values.yaml providers.network)"; \
			else \
				echo "      FAIL $$kind"; echo "$$out" | sed 's/^/           /'; rc=1; \
			fi; \
		done; \
	done; exit $$rc

## Offline Composition check: runs the real functions locally (via Docker) and prints the
## managed resources a Composition would actually create. This is the only local check that
## sees inside a Composition — `make test` cannot (see its note above).
##
## crossplane render takes ONE Composition, a functions file, and needs the EnvironmentConfig
## passed as an extra resource, so the chart output is split apart first. Rendering the whole
## chart at it fails with "not a composition: ClusterProviderConfig/default".
render: ## crossplane render each Composition against its example XR
	@command -v crossplane >/dev/null || { echo "crossplane CLI (v2+) is required"; exit 1; }
	@mkdir -p $(RENDER_OUT)
	@helm template control-plane $(CHART) --values $(VALUES) > $(RENDER_OUT)/all.yaml
	@yq ea 'select(.kind == "Function")' $(RENDER_OUT)/all.yaml > $(RENDER_OUT)/functions.yaml
	@yq ea 'select(.kind == "EnvironmentConfig")' $(RENDER_OUT)/all.yaml > $(RENDER_OUT)/envconfig.yaml
	@# render executes functions locally rather than in-cluster; it needs to be told how.
	@yq -i '.metadata.annotations."render.crossplane.io/runtime" = "Docker"' $(RENDER_OUT)/functions.yaml
	@rc=0; for xr in examples/*.yaml; do \
		kind=$$(yq e '.kind' $$xr); \
		name=$$(basename $$xr .yaml); \
		yq ea "select(.kind == \"Composition\" and .spec.compositeTypeRef.kind == \"$$kind\")" \
			$(RENDER_OUT)/all.yaml > $(RENDER_OUT)/$$name-composition.yaml; \
		[ -s $(RENDER_OUT)/$$name-composition.yaml ] || { echo "FAIL $$name: no Composition for kind $$kind"; rc=1; continue; }; \
		echo "--- render: $$name ($$kind)"; \
		if crossplane render $$xr \
			$(RENDER_OUT)/$$name-composition.yaml \
			$(RENDER_OUT)/functions.yaml \
			--extra-resources=$(RENDER_OUT)/envconfig.yaml \
			> $(RENDER_OUT)/$$name.rendered.yaml 2>$(RENDER_OUT)/$$name.err; then \
			grep -E '^kind:' $(RENDER_OUT)/$$name.rendered.yaml | sed 's/^/      /'; \
		else \
			echo "FAIL $$name:"; sed 's/^/      /' $(RENDER_OUT)/$$name.err; rc=1; \
		fi; \
	done; exit $$rc

## Regenerate the per-environment EnvironmentConfig values from Terraform.
## These IDs are owned by plat-eng-aks-foundation; never hand-edit values-$(ENV).yaml.
## Outputs are read one at a time on purpose. `terraform output -json` with no name emits every
## output including generated SSH keys, whose raw control characters make the document
## unparseable by jq.
##
## The resource group is parsed out of the subnet ID: the foundation exposes no
## resource_group_name output, and the ID is authoritative for the group the network
## actually lives in — which is the group these resources must join.
env-config: ## Regenerate chart/values-$(ENV).yaml from terraform output
	@command -v jq >/dev/null || { echo "jq is required"; exit 1; }
	@test -d $(FOUNDATION) || { echo "foundation not found at $(FOUNDATION)"; exit 1; }
	@echo "Reading terraform outputs from $(FOUNDATION) ..."
	@location=$$(cd $(FOUNDATION) && terraform output -raw location 2>/dev/null); \
	pg_subnet=$$(cd $(FOUNDATION) && terraform output -raw postgres_flexibleserver_subnet_id 2>/dev/null); \
	pg_zone=$$(cd $(FOUNDATION) && terraform output -raw postgres_flexibleserver_private_dns_zone_id 2>/dev/null); \
	pe_subnet=$$(cd $(FOUNDATION) && terraform output -raw private_endpoints_subnet_id 2>/dev/null); \
	redis_zone=$$(cd $(FOUNDATION) && terraform output -json private_dns_zone_ids 2>/dev/null | jq -r '.["privatelink.redis.azure.net"] // empty'); \
	rg=$$(echo "$$pg_subnet" | sed -n 's|.*/resourceGroups/\([^/]*\)/.*|\1|p'); \
	for v in location pg_subnet pg_zone pe_subnet redis_zone rg; do \
		eval "val=\$$$$v"; \
		[ -n "$$val" ] || { echo "ERROR: terraform output for $$v is empty — has 'terraform apply' run in $(FOUNDATION)?"; exit 1; }; \
	done; \
	{ \
		echo "# GENERATED by 'make env-config ENV=$(ENV)'. Do not hand-edit."; \
		echo "# Source: terraform output ($(FOUNDATION)), environment $(ENV)."; \
		echo "# These IDs are owned by plat-eng-aks-foundation. If a subnet or private-DNS"; \
		echo "# zone is recreated, re-run this target — a stale ID surfaces as an XR that"; \
		echo "# never reaches Ready."; \
		echo ""; \
		echo "environmentConfig:"; \
		echo "  location: $$location"; \
		echo "  resourceGroupName: $$rg"; \
		echo "  postgresSubnetId: $$pg_subnet"; \
		echo "  postgresZoneId: $$pg_zone"; \
		echo "  peSubnetId: $$pe_subnet"; \
		echo "  redisZoneId: $$redis_zone"; \
	} > $(VALUES)
	@echo "Wrote $(VALUES)"

all: lint render test verify ## Run every local check
