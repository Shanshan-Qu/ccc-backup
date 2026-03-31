# ── Log Analytics Workspace ────────────────────────────────────────────────────
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

# ── Action groups ──────────────────────────────────────────────────────────────
# Action groups
resource "azurerm_monitor_action_group" "ops" {
  name                = local.action_group_ops
  resource_group_name = module.resource_group.name
  short_name          = "bkp-ops"
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = var.alert_email_receivers
    content {
      name                    = "ops-email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

# Security / platform engineering team
resource "azurerm_monitor_action_group" "security" {
  name                = local.action_group_sec
  resource_group_name = module.resource_group.name
  short_name          = "bkp-sec"
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = var.alert_email_receivers_security
    content {
      name                    = "sec-email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "failed_jobs" {
  name                = "alert-${local.vault_name}-failed-jobs"
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.tags

  description = "Fires when any Azure Backup job fails in the last 30 minutes."
  severity    = 1  # Sev1 – Error

  scopes = [module.log_analytics_workspace.resource_id]

  evaluation_frequency = "PT30M"
  window_duration      = "PT30M"
  auto_mitigation_enabled = true

  criteria {
    query = <<-KQL
      AddonAzureBackupJobs
      | where TimeGenerated > ago(30m)
      | where JobStatus =~ "Failed"
    KQL

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.ops.id]
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "storage_per_item" {
  name                = "alert-${local.vault_name}-storage-per-item"
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.tags

  description = "Fires when a single backup item's consumed storage exceeds 500 GB."
  severity    = 2  # Sev2 – Warning

  scopes = [module.log_analytics_workspace.resource_id]

  evaluation_frequency    = "P1D"
  window_duration         = "P1D"
  auto_mitigation_enabled = true

  criteria {
    # Summarise to the latest storage value per item, then filter.
    # Using summarize+where (rather than a bare row filter) means the alert
    # auto-resolves when no items exceed the threshold any more.
    query = <<-KQL
      AddonAzureBackupStorage
      | where TimeGenerated > ago(1d)
      | summarize StorageConsumedInMBs = max(StorageConsumedInMBs)
          by BackupItemUniqueId, BackupItemFriendlyName, VaultName
      | where StorageConsumedInMBs > 512000
    KQL

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.ops.id]
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "storage_total" {
  name                = "alert-${local.vault_name}-storage-total"
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.tags

  description = "Fires when vault total storage consumption exceeds 1 TB."
  severity    = 2

  scopes = [module.log_analytics_workspace.resource_id]

  evaluation_frequency    = "P1D"
  window_duration         = "P1D"
  auto_mitigation_enabled = true

  criteria {
    # Sum storage across all backup items in the vault, then compare to 1 TB.
    # Previously the query filtered individual rows above 1 TB (same shape as
    # storage-per-item). This corrected query aggregates across all items first.
    query = <<-KQL
      AddonAzureBackupStorage
      | where TimeGenerated > ago(1d)
      | summarize TotalStorageMBs = sum(StorageConsumedInMBs) by VaultName
      | where TotalStorageMBs > 1048576
    KQL

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.ops.id]
  }
}

resource "azurerm_monitor_metric_alert" "backup_health_events" {
  name                = "alert-${local.vault_name}-backup-health"
  resource_group_name = module.resource_group.name
  tags                = local.tags

  description = "Vault backup health event detected (non-Healthy state)."
  severity    = 1
  frequency   = "PT5M"
  window_size = "PT15M"

  scopes = [module.recovery_services_vault.resource_id]

  criteria {
    metric_namespace = "Microsoft.RecoveryServices/vaults"
    metric_name      = "BackupHealthEvent"
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = 0

    dimension {
      name     = "healthStatus"
      operator = "Exclude"
      values   = ["Healthy"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

resource "azurerm_monitor_metric_alert" "restore_health_events" {
  name                = "alert-${local.vault_name}-restore-health"
  resource_group_name = module.resource_group.name
  tags                = local.tags

  description = "Vault restore health event detected (non-Healthy state)."
  severity    = 1
  frequency   = "PT5M"
  window_size = "PT15M"

  scopes = [module.recovery_services_vault.resource_id]

  criteria {
    metric_namespace = "Microsoft.RecoveryServices/vaults"
    metric_name      = "RestoreHealthEvent"
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = 0

    dimension {
      name     = "healthStatus"
      operator = "Exclude"
      values   = ["Healthy"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

resource "azurerm_monitor_activity_log_alert" "resource_health" {
  name                = "alert-${local.vault_name}-resource-health"
  resource_group_name = module.resource_group.name
  location            = "global"
  tags                = local.tags

  description = "Azure platform health state change for the Recovery Services vault."
  scopes      = ["/subscriptions/${var.subscription_id}"]

  criteria {
    category    = "ResourceHealth"
    resource_id = module.recovery_services_vault.resource_id

    resource_health {
      current  = ["Degraded", "Unavailable"]
      previous = ["Available", "Degraded", "Unknown"]
      reason   = ["PlatformInitiated", "UserInitiated", "Unknown"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# Administrative alerts: high-risk vault operations
resource "azurerm_monitor_activity_log_alert" "admin_delete_vault" {
  name                = "alert-${local.vault_name}-admin-delete"
  resource_group_name = module.resource_group.name
  location            = "global"
  tags                = local.tags

  description = "Someone initiated a Delete Vault operation."
  scopes      = ["/subscriptions/${var.subscription_id}"]

  criteria {
    category    = "Administrative"
    resource_id = module.recovery_services_vault.resource_id
    operation_name = "Microsoft.RecoveryServices/vaults/delete"
  }

  action {
    action_group_id = azurerm_monitor_action_group.security.id
  }
}

resource "azurerm_monitor_activity_log_alert" "admin_approve_pe" {
  name                = "alert-${local.vault_name}-admin-approve-pe"
  resource_group_name = module.resource_group.name
  location            = "global"
  tags                = local.tags

  description = "A private endpoint connection on the vault was approved."
  scopes      = ["/subscriptions/${var.subscription_id}"]

  criteria {
    category       = "Administrative"
    resource_id    = module.recovery_services_vault.resource_id
    operation_name = "Microsoft.RecoveryServices/vaults/privateEndpointConnections/write"
  }

  action {
    action_group_id = azurerm_monitor_action_group.security.id
  }
}

resource "azurerm_monitor_activity_log_alert" "admin_security_pin" {
  name                = "alert-${local.vault_name}-admin-security-pin"
  resource_group_name = module.resource_group.name
  location            = "global"
  tags                = local.tags

  description = "A Security PIN (critical ops auth) was retrieved for the vault."
  scopes      = ["/subscriptions/${var.subscription_id}"]

  criteria {
    category       = "Administrative"
    resource_id    = module.recovery_services_vault.resource_id
    operation_name = "Microsoft.RecoveryServices/vaults/backupSecurityPin/action"
  }

  action {
    action_group_id = azurerm_monitor_action_group.security.id
  }
}
