# ==============================================================
# Workload Resources – Test Environment
#
# Subscription constraint notes:
#
#   VM BACKUP:    All VM SKUs return 'NotAvailableForSubscription' in
#                 New Zealand North for this sandbox. Request quota via:
#                 Azure Portal → Subscriptions → Usage + Quotas.
#
#   AZFILES BACKUP: The subscription policy 'deny-storage-sharedkey-access'
#                 enforces allowSharedKeyAccess=false.  Azure Backup for
#                 Azure Files requires allowSharedKeyAccess=true at the
#                 storage account level (confirmed by the error:
#                 "Storage account does not support key based authentication
#                 required for Azure Backup integration").
#                 Resolution: request a policy exception for backup storage
#                 accounts, or wait for Azure Backup to support MSI-based
#                 auth for file share backup.
#
# The networking layer and storage account below are pre-provisioned so that
# both VM and file share backup can be enabled instantly once the above
# constraints are lifted without any infrastructure changes.
# ==============================================================

# ── Unique suffix for the globally-unique Storage Account name ─
resource "random_string" "storage_suffix" {
  length  = 8
  special = false
  upper   = false
  numeric = true
}

# ==============================================================
# Networking
# ==============================================================

resource "azurerm_virtual_network" "workload" {
  name                = "vnet-ccc-backup-${local.region_code}-${var.environment}"
  location            = var.location
  resource_group_name = module.resource_group.name
  address_space       = ["10.100.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "workload" {
  name                 = "snet-workload-${local.region_code}"
  resource_group_name  = module.resource_group.name
  virtual_network_name = azurerm_virtual_network.workload.name
  address_prefixes     = ["10.100.1.0/24"]
}

resource "azurerm_network_security_group" "workload" {
  name                = "nsg-workload-${local.region_code}-${var.environment}"
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.tags

  # Azure Backup extension requires HTTPS to Azure Backup and Storage endpoints.
  security_rule {
    name                       = "AllowAzureBackupOut"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureBackup"
  }

  security_rule {
    name                       = "AllowStorageOut"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Storage"
  }

  security_rule {
    name                       = "AllowAzureADOut"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureActiveDirectory"
  }
}

resource "azurerm_subnet_network_security_group_association" "workload" {
  subnet_id                 = azurerm_subnet.workload.id
  network_security_group_id = azurerm_network_security_group.workload.id
}

# ==============================================================
# Azure Files Workload
# ==============================================================

resource "azurerm_storage_account" "files" {
  name                            = "stccc${random_string.storage_suffix.result}"
  resource_group_name             = module.resource_group.name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false  # Subscription policy enforces this; Azure Backup MSI auth used instead
  tags                            = local.tags
}

# Pre-provisioned file share — ready to register with the vault once
# the allowSharedKeyAccess policy exception is granted:
#
#   resource "azurerm_backup_protected_file_share" "test" {
#     resource_group_name       = module.resource_group.name
#     recovery_vault_name       = module.recovery_services_vault.resource.name
#     source_storage_account_id = azurerm_storage_account.files.id
#     source_file_share_name    = azurerm_storage_share.test.name
#     backup_policy_id          = azurerm_backup_policy_file_share.azfiles.id
#   }
resource "azurerm_storage_share" "test" {
  name               = "ccc-test-share"
  storage_account_id = azurerm_storage_account.files.id
  quota              = 5
}
