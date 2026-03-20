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
  value       = module.log_analytics_workspace.resource.name
}

output "recovery_services_vault_id" {
  description = "Resource ID of the Recovery Services vault."
  value       = module.recovery_services_vault.resource_id
}

output "recovery_services_vault_name" {
  description = "Name of the Recovery Services vault."
  value       = module.recovery_services_vault.resource.name
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

# ==============================================================
# Workload outputs
# ==============================================================

output "workload_storage_account_name" {
  description = "Name of the storage account hosting the test Azure File Share."
  value       = azurerm_storage_account.files.name
}

output "workload_file_share_name" {
  description = "Name of the Azure File Share registered for backup."
  value       = azurerm_storage_share.test.name
}

# workload_vm_* outputs are intentionally omitted: VM SKUs are NotAvailableForSubscription
# in NZN for this sandbox. Once VM quota is granted, add:
#   azurerm_network_interface.vm
#   azurerm_linux_virtual_machine.nonprod (Standard_D2s_v5, Ubuntu 22.04 gen2)
#   azurerm_backup_protected_vm.nonprod (CCC-Policy enhanced V2)
# and expose workload_vm_id / workload_vm_name / workload_vm_ssh_private_key outputs.
