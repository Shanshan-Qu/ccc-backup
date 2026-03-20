# ==============================================================
# terraform.tfvars  –  Test Environment
#
# Fill in all TODO values before running terraform plan/apply.
# ==============================================================

# ── Core ────────────────────────────────────────────────────
subscription_id = "634c603a-fa54-431f-8fdd-2279020b1cb9"
location        = "newzealandnorth"
environment     = "test"
workload        = "backup"

# ── Networking (Private Endpoint) ────────────────────────────
# Leave empty strings if you want to deploy the vault without a
# private endpoint for the initial smoke test.
private_endpoint_subnet_id = ""
# Example:
# private_endpoint_subnet_id = "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>"

private_dns_zone_ids = []
# Example – two zones typically required for RSV private endpoint:
# private_dns_zone_ids = [
#   "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.newzealandnorth.backup.windowsazure.com",
#   "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net",
# ]

# ── Log Analytics ────────────────────────────────────────────
# 90 days covers "30–90 days for investigations & trend analysis" (spec §Monitoring §1)
log_analytics_retention_days = 90

# ── Vault resilience ─────────────────────────────────────────
# false = Disabled (optional for non-prod per spec)
enable_immutability = false

# ── RBAC ─────────────────────────────────────────────────────
# Populate with Entra ID object IDs for the relevant groups/users.
backup_contributor_principal_ids = [
  # "TODO - Entra group or user object ID"
]

backup_operator_principal_ids = [
  # "TODO - Entra group or user object ID"
]

backup_reader_principal_ids = [
  # "TODO - Entra group or user object ID"
]

rsv_contributor_principal_ids = [
  # "TODO - platform engineering Entra group object ID"
]

# ── Alerting ─────────────────────────────────────────────────
alert_email_receivers = [
  # "backup-ops@ccc.govt.nz",
]

alert_email_receivers_security = [
  # "platform-security@ccc.govt.nz",
]

# ── Tags ─────────────────────────────────────────────────────
tags = {
  cost_centre = "TODO"
  project     = "AzureBackup-CCC"
}
