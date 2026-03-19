# ==============================================================
# Backup Policies
#
# Three policies matching the "Initial Backup Policy Schedule"
# in the build spec.  All times are in NZST (UTC+12).
# Policy resources require the vault to exist first.
# ==============================================================

# ──────────────────────────────────────────────────────────────
# 1. VM Non-Production – Enhanced (V2) Policy
#
# Spec:
#   Policy name : CCC-Policy (enhanced)
#   Frequency   : Daily  03:00 NZST
#   Retention   : Daily 7 D | Weekly Sundays 2 W | Monthly First-Sunday 1 M
#   Smart-tier  : TierRecommended (simulate archive tier for future prod use)
# ──────────────────────────────────────────────────────────────
resource "azurerm_backup_policy_vm" "vm_nonprod" {
  name                = "CCC-Policy"
  resource_group_name = module.resource_group.name
  recovery_vault_name = module.recovery_services_vault.resource.name

  # V2 = Enhanced policy (supports sub-hourly backup & tiering)
  policy_type = "V2"
  timezone    = local.nz_timezone

  backup {
    frequency = "Daily"
    time      = "03:00"
  }

  # Snapshot (instant restore) retention – 2 days is sufficient for non-prod
  instant_restore_retention_days = 2

  retention_daily {
    count = 7
  }

  retention_weekly {
    count    = 2
    weekdays = ["Sunday"]
  }

  retention_monthly {
    count    = 1
    weekdays = ["Sunday"]
    weeks    = ["First"]
  }

  depends_on = [module.recovery_services_vault]
}

# ──────────────────────────────────────────────────────────────
# 2. SQL Server on Azure VM Policy
#
# Spec:
#   Policy name  : CCC-SQLPolicy
#   Full backup  : Weekly Saturday  07:00 NZST  →  retain 4 W
#   Differential : Weekdays (Mon–Fri)  18:00 NZST  →  retain 14 D
#   Log backup   : Disabled  (not included)
# ──────────────────────────────────────────────────────────────
resource "azurerm_backup_policy_vm_workload" "sql" {
  name                = "CCC-SQLPolicy"
  resource_group_name = module.resource_group.name
  recovery_vault_name = module.recovery_services_vault.resource.name

  workload_type = "SQLDataBase"

  settings {
    time_zone           = local.nz_timezone
    compression_enabled = false
  }

  # Full weekly backup – Saturday 07:00 NZST, retained 4 weeks
  protection_policy {
    policy_type = "Full"

    backup {
      frequency = "Weekly"
      weekdays  = ["Saturday"]
      time      = "07:00"
    }

    # Spec: retain 4 weeks — retention_weekly covers this; simple_retention
    # is not persisted by the Azure API when retention_weekly is set.
    retention_weekly {
      count    = 4
      weekdays = ["Saturday"]
    }
  }

  # Differential backup – Mon–Fri 18:00 NZST, retained 14 days
  # Note: backup.frequency = Weekly so retention must use simple_retention (days).
  protection_policy {
    policy_type = "Differential"

    backup {
      frequency = "Weekly"
      weekdays  = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
      time      = "18:00"
    }

    simple_retention {
      count = 14  # 14 days
    }
  }

  # Log backup is intentionally omitted (disabled per spec).

  depends_on = [module.recovery_services_vault]
}

# ──────────────────────────────────────────────────────────────
# 3. Azure File Share Policy
#
# Spec:
#   Policy name   : CCC-AzFiles-Policy
#   Backup tier   : Vault-Standard
#   Schedule      : Daily  22:00 NZST
#   Retention     : Daily 30 D | Monthly First-Sunday 3 M | Yearly Jan First-Sunday 1 Y
# ──────────────────────────────────────────────────────────────
resource "azurerm_backup_policy_file_share" "azfiles" {
  name                = "CCC-AzFiles-Policy"
  resource_group_name = module.resource_group.name
  recovery_vault_name = module.recovery_services_vault.resource.name

  timezone = local.nz_timezone

  backup {
    frequency = "Daily"
    time      = "22:00"
  }

  retention_daily {
    count = 30
  }

  retention_monthly {
    count    = 3
    weekdays = ["Sunday"]
    weeks    = ["First"]
  }

  retention_yearly {
    count    = 1
    months   = ["January"]
    weekdays = ["Sunday"]
    weeks    = ["First"]
  }

  depends_on = [module.recovery_services_vault]
}
