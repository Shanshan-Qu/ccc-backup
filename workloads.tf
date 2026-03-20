# ==============================================================
# Workload Resources – Test Environment
#
# Subscription constraint notes:
#
#   VM BACKUP:    All VM SKUs are reported as 'NotAvailableForSubscription'
#                 by the Compute SKUs API in New Zealand North for this sandbox.
#                 Standard_D2as_v6 (AMD Dasv6 family) - Intel Dsv6 unavailable in NZN.
#                 availability.  If this fails, request quota via:
#                 Azure Portal → Subscriptions → Usage + Quotas.
#
#   AZFILES BACKUP: Policy 'StorageAccount_DisableLocalAuth_Modify' (display name:
#                 "SFI-ID4.2.1 Storage Accounts - Safe Secrets Standard") in the
#                 MCAPSGovDeployPolicies initiative actively sets
#                 allowSharedKeyAccess=false on all storage accounts.
#                 Azure Backup for Azure Files requires allowSharedKeyAccess=true.
#                 Resolution: request a policy exemption scoped to this storage
#                 account from the MCAPSGovDeployPolicies assignment owner.
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

# ==============================================================
# Non-Production Linux VM Workload
# Standard_D2s_v5 — confirmed unrestricted in NZN for ShanshanQu-NonProd
# (634c603a-fa54-431f-8fdd-2279020b1cb9)
# ==============================================================

resource "azurerm_network_interface" "vm" {
  name                = "nic-ccc-backup-${local.region_code}-${var.environment}-01"
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.workload.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "tls_private_key" "vm" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine" "nonprod" {
  name                            = "vm-ccc-backup-${local.region_code}-${var.environment}-01"
  location                        = var.location
  resource_group_name             = module.resource_group.name
  size                            = "Standard_D2s_v5"
  admin_username                  = "cccadmin"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vm.id]
  tags                            = local.tags

  admin_ssh_key {
    username   = "cccadmin"
    public_key = tls_private_key.vm.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # Seed test data on first boot via cloud-init.
  custom_data = base64encode(<<-CLOUDINIT
    #!/bin/bash
    mkdir -p /opt/ccc-testdata
    echo "=== CCC Azure Backup Test Workload ===" > /opt/ccc-testdata/sample.txt
    echo "Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /opt/ccc-testdata/sample.txt
    for i in $(seq 1 100); do
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | Workload record $i | INFO | Simulated application log entry" >> /opt/ccc-testdata/workload.log
    done
    chmod -R 644 /opt/ccc-testdata/
    echo "CCC test data seeded at $(date -u)" >> /var/log/ccc-backup-init.log
  CLOUDINIT
  )
}

# Register VM with the vault and assign the CCC-Policy (V2 enhanced).
# Azure Backup automatically installs the VMSnapshotLinux extension
# on the VM before the first backup runs.
resource "azurerm_backup_protected_vm" "nonprod" {
  resource_group_name = module.resource_group.name
  recovery_vault_name = module.recovery_services_vault.resource.name
  source_vm_id        = azurerm_linux_virtual_machine.nonprod.id
  backup_policy_id    = azurerm_backup_policy_vm.vm_nonprod.id

  depends_on = [azurerm_linux_virtual_machine.nonprod]
}
