#!/usr/bin/env bash
# Azure side of the Order Desk demo. Safe to run again.
#
# Creates App Service (Linux, Node.js), Application Insights, and a user-assigned managed identity that
# GitHub Actions signs in as with OpenID Connect (OIDC). No password, client secret or publish profile is stored.
# The identity gets Website Contributor on this one web app and trusts tokens only from the repository's
# "production" environment.
#
# Based on Microsoft Learn: "Deploy to Azure App Service by using GitHub Actions" (OpenID Connect,
# user-assigned identity, Website Contributor), "Authenticate to Azure from GitHub Actions by OpenID Connect",
# and GitHub Docs: "OpenID Connect reference" (subject claims, including the immutable format).
#
# Easiest place to run it: Azure Cloud Shell (Bash), which has az, gh, git and node.
#   az account set --subscription <subscription-id>      # if you have more than one
#   gh auth login                                        # as an admin of the GitHub repository
#   git clone https://github.com/<owner>/<repo> && cd <repo>
#   scripts/azure-setup.sh
#
# Optional settings (environment variables), with defaults:
#   REPO=<owner/name of the clone>  LOCATION=southeastasia  RG=rg-contoso-order-desk  PLAN=asp-contoso-order-desk
#   APP=<unique name, reused on reruns>  SKU=B1  RUNTIME=NODE:24-lts  IDENTITY=id-github-order-desk
#   SUBJECT_FORMAT=auto|immutable|legacy   APPINSIGHTS=1   DEPLOY=1 (start the first deployment at the end)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

need az "Use Azure Cloud Shell, or install the Azure CLI and run: az login"
need gh "Install it from https://cli.github.com/ and run: gh auth login"
export AZURE_EXTENSION_USE_DYNAMIC_INSTALL=yes_without_prompt

resolve_repo
require_admin
az account show -o none 2>/dev/null || die "Sign in to Azure first: az login"

LOCATION=${LOCATION:-southeastasia}
RG=${RG:-rg-contoso-order-desk}
PLAN=${PLAN:-asp-contoso-order-desk}
SKU=${SKU:-B1}
RUNTIME=${RUNTIME:-NODE:24-lts}
IDENTITY=${IDENTITY:-id-github-order-desk}
APPINSIGHTS=${APPINSIGHTS:-1}
DEPLOY=${DEPLOY:-1}
SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

default_app_name() {
  local owner
  owner=$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | cut -c1-24)
  printf 'order-desk-%s-%s' "${owner%-}" "$(printf '%s' "$SUB_ID" | tr -d '-' | cut -c1-6)"
}
APP=${APP:-$(gh variable get AZURE_WEBAPP_NAME -R "$REPO" 2>/dev/null || default_app_name)}

gh api "repos/$REPO/environments/production" --silent 2>/dev/null \
  || die "The 'production' environment does not exist yet. Run scripts/github-setup.sh first, so it has its approval rule before anything deploys."
REVIEWERS=$(gh api "repos/$REPO/environments/production" --jq '[.protection_rules[]? | select(.type == "required_reviewers")] | length')
[ "$REVIEWERS" != "0" ] || warn "The 'production' environment has no required reviewer, so deployments will not wait for approval. Fix it with scripts/github-setup.sh or in Settings > Environments."

step "Deploying the Order Desk demo for $REPO"
info "Subscription $(az account show --query name -o tsv) ($SUB_ID)"
info "Resource group $RG in $LOCATION; web app $APP; plan $PLAN ($SKU)"
confirm "Create or update these Azure resources (an App Service plan $SKU has an hourly cost until you delete it)?"

# --------------------------------------------------------------------------------------------
step "1/6 Resource group and App Service plan"
az group create -n "$RG" -l "$LOCATION" --tags workload=contoso-order-desk purpose=demo -o none
ok "Resource group $RG"
if az appservice plan show -g "$RG" -n "$PLAN" -o none 2>/dev/null; then
  ok "App Service plan $PLAN (exists)"
else
  az appservice plan create -g "$RG" -n "$PLAN" --is-linux --sku "$SKU" -o none
  ok "App Service plan $PLAN (Linux, $SKU)"
fi

# --------------------------------------------------------------------------------------------
step "2/6 Web app $APP"
if az webapp show -g "$RG" -n "$APP" -o none 2>/dev/null; then
  ok "Web app exists"
elif az webapp create -g "$RG" -p "$PLAN" -n "$APP" --runtime "$RUNTIME" -o none; then
  ok "Web app created ($RUNTIME)"
else
  warn "Could not create the web app with $RUNTIME (check: az webapp list-runtimes --os-type linux). Trying NODE:22-lts."
  az webapp create -g "$RG" -p "$PLAN" -n "$APP" --runtime NODE:22-lts -o none
  ok "Web app created (NODE:22-lts; the app runs on Node.js 22 as well)"
fi
az webapp update -g "$RG" -n "$APP" --https-only true -o none
az webapp config set -g "$RG" -n "$APP" --always-on true --ftps-state Disabled --min-tls-version 1.2 \
  --http20-enabled true --generic-configurations '{"healthCheckPath": "/health"}' -o none
ok "HTTPS only, TLS 1.2+, FTP off, Always On, health check /health"
for policy in scm ftp; do
  az resource update -g "$RG" --namespace Microsoft.Web --resource-type basicPublishingCredentialsPolicies \
    --parent "sites/$APP" -n "$policy" --set properties.allow=false -o none
done
ok "Basic authentication (publishing credentials) turned off; deployments use Microsoft Entra ID"

# --------------------------------------------------------------------------------------------
step "3/6 Monitoring"
if [ "$APPINSIGHTS" = "1" ]; then
  WORKSPACE=log-contoso-order-desk
  az monitor log-analytics workspace show -g "$RG" -n "$WORKSPACE" -o none 2>/dev/null \
    || az monitor log-analytics workspace create -g "$RG" -n "$WORKSPACE" -l "$LOCATION" -o none
  WORKSPACE_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$WORKSPACE" --query id -o tsv)
  az monitor app-insights component show -g "$RG" --app appi-contoso-order-desk -o none 2>/dev/null \
    || az monitor app-insights component create -g "$RG" --app appi-contoso-order-desk -l "$LOCATION" \
         --workspace "$WORKSPACE_ID" --kind web --application-type web -o none
  CONNECTION=$(az monitor app-insights component show -g "$RG" --app appi-contoso-order-desk --query connectionString -o tsv)
  az webapp config appsettings set -g "$RG" -n "$APP" -o none --settings \
    "APPLICATIONINSIGHTS_CONNECTION_STRING=$CONNECTION" "ApplicationInsightsAgent_EXTENSION_VERSION=~3"
  ok "Application Insights (auto-instrumentation) with a Log Analytics workspace"
else
  info "Skipped (APPINSIGHTS=0)"
fi

# --------------------------------------------------------------------------------------------
step "4/6 Identity for GitHub Actions: $IDENTITY"
az identity show -g "$RG" -n "$IDENTITY" -o none 2>/dev/null || az identity create -g "$RG" -n "$IDENTITY" -l "$LOCATION" -o none
CLIENT_ID=$(az identity show -g "$RG" -n "$IDENTITY" --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -g "$RG" -n "$IDENTITY" --query principalId -o tsv)
WEBAPP_ID=$(az webapp show -g "$RG" -n "$APP" --query id -o tsv)
if [ -n "$(az role assignment list --assignee "$PRINCIPAL_ID" --scope "$WEBAPP_ID" --role "Website Contributor" --query '[].id' -o tsv)" ]; then
  ok "Website Contributor on $APP (exists)"
else
  for attempt in 1 2 3 4 5 6; do
    if az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
         --role "Website Contributor" --scope "$WEBAPP_ID" -o none 2>/dev/null; then
      ok "Website Contributor on $APP only"
      break
    fi
    [ "$attempt" = 6 ] && die "Could not assign the role. You need Owner or User Access Administrator on the resource group."
    info "Waiting for the new identity to replicate ($attempt/6)..."
    sleep 10
  done
fi

# --------------------------------------------------------------------------------------------
step "5/6 Federated credential: trust only the 'production' environment of $REPO"
REPO_ID=$(gh api "repos/$REPO" --jq .id)
OWNER_ID=$(gh api "repos/$REPO" --jq .owner.id)
CREATED=$(gh api "repos/$REPO" --jq .created_at)
SUBJECT_FORMAT=${SUBJECT_FORMAT:-auto}
if [ "$SUBJECT_FORMAT" = "auto" ]; then
  # GitHub Docs: repositories created after 15 July 2026 use the immutable format with owner and repository IDs.
  if [[ "$CREATED" > "2026-07-16" ]]; then SUBJECT_FORMAT=immutable; else SUBJECT_FORMAT=legacy; fi
fi
if [ "$SUBJECT_FORMAT" = "immutable" ]; then
  SUBJECT="repo:$OWNER@$OWNER_ID/$NAME@$REPO_ID:environment:production"
else
  SUBJECT="repo:$OWNER/$NAME:environment:production"
fi
if az identity federated-credential show -g "$RG" --identity-name "$IDENTITY" -n github-production -o none 2>/dev/null; then
  az identity federated-credential update -g "$RG" --identity-name "$IDENTITY" -n github-production \
    --issuer https://token.actions.githubusercontent.com --subject "$SUBJECT" --audiences api://AzureADTokenExchange -o none
else
  az identity federated-credential create -g "$RG" --identity-name "$IDENTITY" -n github-production \
    --issuer https://token.actions.githubusercontent.com --subject "$SUBJECT" --audiences api://AzureADTokenExchange -o none
fi
ok "Subject ($SUBJECT_FORMAT format): $SUBJECT"
info "If sign-in fails with AADSTS70021, the error shows the subject GitHub sent: rerun with SUBJECT_FORMAT=legacy or immutable to match."

# --------------------------------------------------------------------------------------------
step "6/6 GitHub: environment secrets and the web app name"
gh secret set AZURE_CLIENT_ID --env production --body "$CLIENT_ID" -R "$REPO"
gh secret set AZURE_TENANT_ID --env production --body "$TENANT_ID" -R "$REPO"
gh secret set AZURE_SUBSCRIPTION_ID --env production --body "$SUB_ID" -R "$REPO"
gh variable set AZURE_WEBAPP_NAME --body "$APP" -R "$REPO"
ok "Secrets AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID on the 'production' environment"
ok "Variable AZURE_WEBAPP_NAME=$APP (the deploy job is skipped while it is empty)"

HOST=$(az webapp show -g "$RG" -n "$APP" --query defaultHostName -o tsv)
if [ "$DEPLOY" = "1" ]; then
  gh workflow run ci-cd.yml -R "$REPO" --ref main >/dev/null \
    && ok "Started the first CI/CD run on main. The approver approves the 'production' deployment in the Actions tab." \
    || warn "Could not start CI/CD. Run it from the Actions tab (CI/CD > Run workflow)."
fi

step "Done${WARNINGS:+ with $WARNINGS warning(s)}"
cat <<NEXT
  Web app:   https://$HOST   (health: https://$HOST/health)
  Resources: resource group $RG in subscription $SUB_ID
  Remove everything after the workshop with: scripts/cleanup-azure.sh
NEXT
