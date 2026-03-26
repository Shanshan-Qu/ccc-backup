# ── Private DNS Zones for Azure Backup vault private endpoint ──────────────────
#
# Three zones are required for the AzureBackup subresource in NZ North
# (confirmed via: az network private-link-resource list ... --group-id AzureBackup).
#
# 1. privatelink.nzn.backup.windowsazure.com  – backup service endpoint
# 2. privatelink.queue.core.windows.net        – internal queue storage
# 3. privatelink.blob.core.windows.net         – internal blob storage

resource "azurerm_private_dns_zone" "backup" {
  name                = "privatelink.nzn.backup.windowsazure.com"
  resource_group_name = module.resource_group.name
  tags                = local.tags

  depends_on = [module.resource_group]
}

resource "azurerm_private_dns_zone" "backup_queue" {
  name                = "privatelink.queue.core.windows.net"
  resource_group_name = module.resource_group.name
  tags                = local.tags

  depends_on = [module.resource_group]
}

resource "azurerm_private_dns_zone" "backup_blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = module.resource_group.name
  tags                = local.tags

  depends_on = [module.resource_group]
}

# ── VNet links – all three zones must be linked so in-VNet DNS resolves correctly

resource "azurerm_private_dns_zone_virtual_network_link" "backup" {
  name                  = "pdnslink-backup-${local.region_code}-${var.environment}"
  resource_group_name   = module.resource_group.name
  private_dns_zone_name = azurerm_private_dns_zone.backup.name
  virtual_network_id    = module.workload_vnet.resource_id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "backup_queue" {
  name                  = "pdnslink-backup-queue-${local.region_code}-${var.environment}"
  resource_group_name   = module.resource_group.name
  private_dns_zone_name = azurerm_private_dns_zone.backup_queue.name
  virtual_network_id    = module.workload_vnet.resource_id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "backup_blob" {
  name                  = "pdnslink-backup-blob-${local.region_code}-${var.environment}"
  resource_group_name   = module.resource_group.name
  private_dns_zone_name = azurerm_private_dns_zone.backup_blob.name
  virtual_network_id    = module.workload_vnet.resource_id
  registration_enabled  = false
  tags                  = local.tags
}
