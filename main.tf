# ==============================================================
# Resource Group
# AVM: https://registry.terraform.io/modules/Azure/avm-res-resources-resourcegroup
# ==============================================================
module "resource_group" {
  source  = "Azure/avm-res-resources-resourcegroup/azurerm"
  version = "~> 0.2"

  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

# ==============================================================
# Log Analytics Workspace
# AVM: https://registry.terraform.io/modules/Azure/avm-res-operationalinsights-workspace
# Centralises backup telemetry, fulfils spec §Monitoring §1.
# ==============================================================
module "log_analytics_workspace" {
  source  = "Azure/avm-res-operationalinsights-workspace/azurerm"
  version = "~> 0.4"

  name                = local.law_name
  location            = var.location
  resource_group_name = module.resource_group.name

  log_analytics_workspace_retention_in_days = var.log_analytics_retention_days

  tags = local.tags

  depends_on = [module.resource_group]
}

# ==============================================================
# Recovery Services Vault  (non-production)
# AVM: https://registry.terraform.io/modules/Azure/avm-res-recoveryservices-vault
#
# Spec settings (non-prod column):
#   Storage redundancy        → LRS
#   Encryption at rest        → Microsoft-managed (default)
#   Enhanced Soft Delete      → AlwaysON  (mandatory baseline)
#   Vault immutability        → Disabled  (optional for non-prod)
#   Multi-User Authorisation  → Disabled  (optional for non-prod)
#   Public access             → Disabled  (private endpoint)
# ==============================================================
module "recovery_services_vault" {
  source  = "Azure/avm-res-recoveryservices-vault/azurerm"
  version = "~> 0.3"

  name                = local.vault_name
  location            = var.location
  resource_group_name = module.resource_group.name

  # ── SKU ─────────────────────────────────────────────────────
  sku = "Standard"

  # ── Storage redundancy ──────────────────────────────────────
  # Non-prod: LRS (reduces cost).  Prod would be ZRS or GRS.
  storage_mode_type = "LocallyRedundant"

  # CRR requires GRS; not applicable for LRS vaults.
  cross_region_restore_enabled = false

  # ── Soft Delete ─────────────────────────────────────────────
  # Spec mandates soft delete as a baseline for all vaults.
  soft_delete_enabled = true

  # ── Immutability ────────────────────────────────────────────
  # Unlocked = protection is active but admin can still lock/disable.
  # Disabled by default for non-prod; toggle with enable_immutability.
  immutability = var.enable_immutability ? "Unlocked" : "Disabled"

  # ── Network ─────────────────────────────────────────────────
  # Disable public access; vault is reachable only via private endpoint.
  public_network_access_enabled = false

  # ── Private Endpoint ────────────────────────────────────────
  # Created only when private_endpoint_subnet_id is supplied.
  private_endpoints = local.vault_private_endpoints

  # ── Diagnostics → Log Analytics ─────────────────────────────
  # Sends all Azure Backup log categories to the LAW (spec §Monitoring §1).
  diagnostic_settings = {
    to_law = {
      name                  = "diag-${local.vault_name}-law"
      workspace_resource_id = module.log_analytics_workspace.resource_id
      log_groups            = ["allLogs"]
      metric_categories     = ["AllMetrics"]
    }
  }

  # ── RBAC ────────────────────────────────────────────────────
  # Roles: Backup Contributor / Operator / Reader + RSV Contributor.
  # Principal IDs are supplied via variables.
  role_assignments = local.vault_role_assignments

  tags = local.tags

  depends_on = [
    module.resource_group,
    module.log_analytics_workspace,
  ]
}
