module "resource_group" {
  source  = "Azure/avm-res-resources-resourcegroup/azurerm"
  version = "~> 0.2"

  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

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

# VNet/Subnet stay as raw resources (networking.tf): the VNet AVM >= 0.7
# switched internally to azapi_resource, making state migration impossible
# without a destroy/recreate cycle.

module "workload_nsg" {
  source  = "Azure/avm-res-network-networksecuritygroup/azurerm"
  version = "~> 0.2"

  name                = "nsg-workload-${local.region_code}-${var.environment}"
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.tags

  security_rules = {
    AllowAzureBackupOut = {
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
    AllowStorageOut = {
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
    AllowAzureADOut = {
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

  depends_on = [module.resource_group]
}

module "files_storage" {
  source  = "Azure/avm-res-storage-storageaccount/azurerm"
  version = "~> 0.2"

  name                            = "stccc${random_string.storage_suffix.result}"
  resource_group_name             = module.resource_group.name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  tags                            = local.tags

  # File share is managed as a raw resource in networking.tf.
  # The storage AVM >= 0.4 uses azapi_resource for shares internally,
  # which is incompatible with the existing azurerm_storage_share state entry.

  role_assignments = {
    vault_backup_contributor = {
      role_definition_id_or_name = "Storage Account Backup Contributor"
      principal_id               = module.recovery_services_vault.resource.identity[0].principal_id
    }
    bms_backup_contributor = {
      role_definition_id_or_name = "Storage Account Backup Contributor"
      principal_id               = "1de5ba0f-6130-42ed-8bcf-1f5ecca84aec" # Backup Management Service SPN
    }
  }

  depends_on = [module.resource_group, module.recovery_services_vault]
}

# Non-production Linux VM
module "nonprod_vm" {
  source  = "Azure/avm-res-compute-virtualmachine/azurerm"
  version = "~> 0.15"

  name                = "vm-ccc-${var.workload}-${local.region_code}-${var.environment}-01"
  resource_group_name = module.resource_group.name
  location            = var.location
  os_type             = "Linux"
  sku_size            = "Standard_D2s_v5"
  tags                = local.tags

  zone = null # no zone preference; NZN has limited zone availability

  encryption_at_host_enabled = false # Microsoft.Compute/EncryptionAtHost not registered on this subscription

  account_credentials = {
    admin_credentials = {
      username                           = "cccadmin"
      ssh_keys                           = [tls_private_key.vm.public_key_openssh]
      generate_admin_password_or_ssh_key = false
    }
    password_authentication_disabled = true
  }

  source_image_reference = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk = {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  network_interfaces = {
    primary = {
      name = "nic-ccc-${var.workload}-${local.region_code}-${var.environment}-01"
      ip_configurations = {
        primary = {
          name                          = "internal"
          private_ip_address_allocation = "Dynamic"
          private_ip_subnet_resource_id = azurerm_subnet.workload.id
        }
      }
    }
  }

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

  depends_on = [module.resource_group, azurerm_subnet.workload]
}

# SQL Server 2022 Developer on Windows Server 2022
module "sql_vm" {
  source  = "Azure/avm-res-compute-virtualmachine/azurerm"
  version = "~> 0.15"

  name          = "vm-ccc-sql-${local.region_code}-${var.environment}-01"
  resource_group_name = module.resource_group.name
  location      = var.location
  os_type       = "Windows"
  sku_size      = "Standard_D4s_v5"
  computer_name = "ccc-sql-nzn01"
  tags          = local.tags

  zone = null

  encryption_at_host_enabled = false # Microsoft.Compute/EncryptionAtHost not registered on this subscription

  account_credentials = {
    admin_credentials = {
      username                           = "cccadmin"
      generate_admin_password_or_ssh_key = true
    }
  }

  source_image_reference = {
    publisher = "MicrosoftSQLServer"
    offer     = "sql2022-ws2022"
    sku       = "sqldev-gen2"
    version   = "latest"
  }

  os_disk = {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  network_interfaces = {
    primary = {
      name = "nic-ccc-sql-${local.region_code}-${var.environment}-01"
      ip_configurations = {
        primary = {
          name                          = "internal"
          private_ip_address_allocation = "Dynamic"
          private_ip_subnet_resource_id = azurerm_subnet.workload.id
        }
      }
    }
  }

  depends_on = [module.resource_group, azurerm_subnet.workload]
}

# Recovery Services Vault
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

  private_endpoints = local.vault_private_endpoints

  diagnostic_settings = {
    to_law = {
      name                  = "diag-${local.vault_name}-law"
      workspace_resource_id = module.log_analytics_workspace.resource_id
      log_groups            = ["allLogs"]
      metric_categories     = ["AllMetrics"]
    }
  }

  role_assignments = local.vault_role_assignments

  managed_identities = {
    system_assigned = true
  }

  vm_backup_policy = {
    "ccc-policy" = {
      name                           = "CCC-Policy"
      timezone                       = local.nz_timezone
      policy_type                    = "V2"
      frequency                      = "Daily"
      instant_restore_retention_days = 2
      backup = {
        time = "03:00"
      }
      retention_daily = 7
      retention_weekly = {
        count    = 2
        weekdays = ["Sunday"]
      }
      retention_monthly = {
        count    = 1
        weekdays = ["Sunday"]
        weeks    = ["First"]
      }
    }
  }

  file_share_backup_policy = {
    "ccc-azfiles-policy" = {
      name      = "CCC-AzFiles-Policy"
      timezone  = local.nz_timezone
      frequency = "Daily"
      backup = {
        time = "22:00"
      }
      retention_daily = 30
      retention_monthly = {
        count    = 3
        weekdays = ["Sunday"]
        weeks    = ["First"]
      }
      retention_yearly = {
        count    = 1
        months   = ["January"]
        weekdays = ["Sunday"]
        weeks    = ["First"]
      }
    }
  }

  workload_backup_policy = {
    "ccc-sqlpolicy" = {
      name          = "CCC-SQLPolicy"
      workload_type = "SQLDataBase"
      settings = {
        time_zone           = local.nz_timezone
        compression_enabled = false
      }
      backup_frequency = "Weekly"
      protection_policy = {
        full = {
          policy_type           = "Full"
          retention_daily_count = 7
          backup = {
            time     = "07:00"
            weekdays = ["Saturday"]
          }
          retention_weekly = {
            count    = 4
            weekdays = ["Saturday"]
          }
        }
        differential = {
          policy_type           = "Differential"
          retention_daily_count = 14
          backup = {
            time     = "18:00"
            weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
          }
        }
      }
    }
  }

  tags = local.tags

  depends_on = [
    module.resource_group,
    module.log_analytics_workspace,
  ]
}
