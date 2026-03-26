module "recovery_services_vault" {
  source  = "Azure/avm-res-recoveryservices-vault/azurerm"
  version = "~> 0.3"

  name                = local.vault_name
  location            = var.location
  resource_group_name = module.resource_group.name

  sku                           = "Standard"
  storage_mode_type             = "LocallyRedundant"
  cross_region_restore_enabled  = false
  soft_delete_enabled           = true
  immutability                  = var.enable_immutability ? "Unlocked" : "Disabled"
  public_network_access_enabled = false  # vault is accessible only via private endpoint (spec requirement)

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
    "ccc-vm-policy" = {
      name                           = "CCC-VM-Policy"
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
    "ccc-sql-workload-policy" = {
      name          = "CCC-SQL-Workload-Policy"
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
