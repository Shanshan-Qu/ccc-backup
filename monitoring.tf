# ==============================================================
# Monitoring, Alerting & Action Groups
#
# Implements the alerting strategy from spec §Monitoring §3.
# Covers:
#   •  Action groups   (ops + security/platform)
#   •  Failed Jobs     (Log Analytics scheduled-query alert)
#   •  Storage growth  (Log Analytics scheduled-query alerts)
#   •  Backup/Restore Health Events  (Metric alerts)
#   •  Resource Health (Activity-log alert)
#   •  Administrative operations (Activity-log alerts)
# ==============================================================

# ──────────────────────────────────────────────────────────────
# Action Groups
# ──────────────────────────────────────────────────────────────

# Backup operations / on-call team
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

# Security / platform engineering team (admin events)
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

# ──────────────────────────────────────────────────────────────
# Scheduled-Query (Log Analytics) Alert – All Failed Jobs
#
# Spec §Monitoring §3: "All Failed Jobs (Log Analytics alert rule):
#  create an alert when failures > 0 in a rolling window (15–60 min)."
# ──────────────────────────────────────────────────────────────
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
      | project TimeGenerated, VaultName, BackupItemFriendlyName,
                WorkloadType, OperationName, JobFailureCode
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

# ──────────────────────────────────────────────────────────────
# Scheduled-Query Alert – Cloud Storage Growth Per Backup Item
#
# Spec §Monitoring §3: "alert on abnormal growth (e.g. day-over-day %
# increase or crossing a per-item threshold)."
# Baseline threshold: alert when any single item exceeds 500 GB.
# Adjust the threshold via the KQL where clause to suit.
# ──────────────────────────────────────────────────────────────
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "storage_per_item" {
  name                = "alert-${local.vault_name}-storage-per-item"
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.tags

  description = "Fires when a single backup item's consumed storage exceeds the threshold."
  severity    = 2  # Sev2 – Warning

  scopes = [module.log_analytics_workspace.resource_id]

  evaluation_frequency = "P1D"
  window_duration      = "P1D"
  auto_mitigation_enabled = true

  criteria {
    query = <<-KQL
      AddonAzureBackupStorage
      | where TimeGenerated > ago(1d)
      | summarize StorageGB = max(StorageConsumedInMBs) / 1024.0
          by BackupItemFriendlyName, VaultName, StorageType
      | where StorageGB > 500
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

# ──────────────────────────────────────────────────────────────
# Scheduled-Query Alert – Total Cloud Storage Trend
#
# Spec §Monitoring §3: "alert when total consumption crosses defined
# thresholds or growth rate materially changes."
# ──────────────────────────────────────────────────────────────
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "storage_total" {
  name                = "alert-${local.vault_name}-storage-total"
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.tags

  description = "Fires when vault total storage consumption exceeds 1 TB."
  severity    = 2

  scopes = [module.log_analytics_workspace.resource_id]

  evaluation_frequency = "P1D"
  window_duration      = "P1D"
  auto_mitigation_enabled = true

  criteria {
    query = <<-KQL
      AddonAzureBackupStorage
      | where TimeGenerated > ago(1d)
      | summarize TotalTB = sum(StorageConsumedInMBs) / (1024.0 * 1024.0) by VaultName
      | where TotalTB > 1
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

# ──────────────────────────────────────────────────────────────
# Metric Alert – Backup Health Events
#
# Spec §Monitoring §3: "alert on relevant health event counts/conditions."
# ──────────────────────────────────────────────────────────────
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
      operator = "NotEquals"
      values   = ["Healthy"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# ──────────────────────────────────────────────────────────────
# Metric Alert – Restore Health Events
#
# Spec §Monitoring §3: "alert on restore health event conditions,
# especially for production vaults."
# ──────────────────────────────────────────────────────────────
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
      operator = "NotEquals"
      values   = ["Healthy"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# ──────────────────────────────────────────────────────────────
# Resource Health Alert – Vault Availability
#
# Spec §Monitoring §3: "alert immediately on health state changes
# (Degraded/Unavailable) for any production vaults."
# ──────────────────────────────────────────────────────────────
resource "azurerm_monitor_activity_log_alert" "resource_health" {
  name                = "alert-${local.vault_name}-resource-health"
  resource_group_name = module.resource_group.name
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

# ──────────────────────────────────────────────────────────────
# Activity Log Alerts – High-risk Administrative Operations
#
# Spec §Monitoring §3: "alert on high-risk events at minimum:
#   Delete Vault, Approve Private Endpoint, Export Jobs,
#   Get Security PIN Info, and other sensitive control-plane actions."
# ──────────────────────────────────────────────────────────────

resource "azurerm_monitor_activity_log_alert" "admin_delete_vault" {
  name                = "alert-${local.vault_name}-admin-delete"
  resource_group_name = module.resource_group.name
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

resource "azurerm_monitor_activity_log_alert" "admin_export_jobs" {
  name                = "alert-${local.vault_name}-admin-export-jobs"
  resource_group_name = module.resource_group.name
  tags                = local.tags

  description = "A backup job export operation was triggered."
  scopes      = ["/subscriptions/${var.subscription_id}"]

  criteria {
    category       = "Administrative"
    resource_id    = module.recovery_services_vault.resource_id
    operation_name = "Microsoft.RecoveryServices/vaults/backupJobs/export/action"
  }

  action {
    action_group_id = azurerm_monitor_action_group.security.id
  }
}

resource "azurerm_monitor_activity_log_alert" "admin_security_pin" {
  name                = "alert-${local.vault_name}-admin-security-pin"
  resource_group_name = module.resource_group.name
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
