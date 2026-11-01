#!/usr/bin/env bash
# Deletes the demo's Azure resources (the whole resource group) and the Azure settings stored in GitHub.
#   RG=rg-contoso-order-desk scripts/cleanup-azure.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh
need az; need gh
resolve_repo
RG=${RG:-rg-contoso-order-desk}
az group show -n "$RG" -o none 2>/dev/null || die "Resource group $RG not found in subscription $(az account show --query name -o tsv)."

step "Delete resource group $RG and everything in it"
az resource list -g "$RG" --query '[].{name:name, type:type}' -o table
confirm "Delete these resources permanently?"
az group delete -n "$RG" --yes --no-wait
ok "Deletion started (it takes a few minutes): web app, plan, identity and its federated credential, monitoring"

step "Remove the Azure settings from $REPO"
for s in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID; do
  gh secret delete "$s" --env production -R "$REPO" >/dev/null 2>&1 && ok "Deleted environment secret $s" || true
done
gh variable delete AZURE_WEBAPP_NAME -R "$REPO" >/dev/null 2>&1 && ok "Deleted variable AZURE_WEBAPP_NAME (the deploy job is skipped from now on)" || true
