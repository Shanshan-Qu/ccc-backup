output "resource_group_name" {
  description = "Name of the resource group containing all backup resources."
  value       = module.resource_group.name
}

output "resource_group_id" {
  description = "Resource ID of the backup resource group."
  value       = module.resource_group.resource_id
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace."
  value       = module.log_analytics_workspace.resource_id
}

output "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace."
  value       = module.log_analytics_workspace.name
}

output "recovery_services_vault_id" {
  description = "Resource ID of the Recovery Services vault."
  value       = module.recovery_services_vault.resource_id
}

output "recovery_services_vault_name" {
  description = "Name of the Recovery Services vault."
  value       = module.recovery_services_vault.name
}

output "backup_policy_vm_nonprod_id" {
  description = "Resource ID of the VM non-prod (CCC-Policy enhanced V2) backup policy."
  value       = azurerm_backup_policy_vm.vm_nonprod.id
}

output "backup_policy_sql_id" {
  description = "Resource ID of the SQL Server workload (CCC-SQLPolicy) backup policy."
  value       = azurerm_backup_policy_vm_workload.sql.id
}

output "backup_policy_azfiles_id" {
  description = "Resource ID of the Azure File Share (CCC-AzFiles-Policy) backup policy."
  value       = azurerm_backup_policy_file_share.azfiles.id
}

output "action_group_ops_id" {
  description = "Resource ID of the backup operations action group."
  value       = azurerm_monitor_action_group.ops.id
}

output "action_group_security_id" {
  description = "Resource ID of the security / platform ops action group."
  value       = azurerm_monitor_action_group.security.id
}
