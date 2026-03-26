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
  description = "Resource ID of the VM non-prod backup policy."
  value       = module.recovery_services_vault.recovery_services_vault_vm_policy["ccc-vm-policy"].resource_id
}

output "backup_policy_sql_id" {
  description = "Resource ID of the SQL Server workload backup policy."
  value       = module.recovery_services_vault.recovery_workload_policy["ccc-sql-workload-policy"].resource_id
}

output "backup_policy_azfiles_id" {
  description = "Resource ID of the Azure File Share (CCC-AzFiles-Policy) backup policy."
  value       = module.recovery_services_vault.recovery_services_vault_file_share_policy["ccc-azfiles-policy"].resource_id
}

output "action_group_ops_id" {
  description = "Resource ID of the backup operations action group."
  value       = azurerm_monitor_action_group.ops.id
}

output "action_group_security_id" {
  description = "Resource ID of the security / platform ops action group."
  value       = azurerm_monitor_action_group.security.id
}

output "workload_storage_account_name" {
  description = "Name of the storage account hosting the test Azure File Share."
  value       = module.files_storage.resource.name
}

output "workload_file_share_name" {
  description = "Name of the Azure File Share registered for backup."
  value       = azurerm_storage_share.test.name
}

output "workload_vm_id" {
  description = "Resource ID of the non-prod test VM registered for backup."
  value       = module.nonprod_vm.resource_id
}

output "workload_vm_name" {
  description = "Name of the non-prod test VM."
  value       = module.nonprod_vm.name
}

output "workload_vm_ssh_private_key" {
  description = "PEM-encoded SSH private key for the test VM (non-prod only — do not use in production)."
  value       = tls_private_key.vm.private_key_pem
  sensitive   = true
}

output "sql_vm_id" {
  description = "Resource ID of the SQL Server VM registered for workload backup."
  value       = module.sql_vm.resource_id
}

output "sql_vm_name" {
  description = "Name of the SQL Server VM."
  value       = module.sql_vm.name
}

output "sql_vm_admin_password" {
  description = "Generated admin password for the SQL Server VM (sensitive)."
  value       = module.sql_vm.admin_password
  sensitive   = true
}

output "sql_admin_login" {
  description = "SQL Server sysadmin login created by the IaaS extension (used by the test script)."
  value       = "ccc_sqladmin"
}

output "sql_admin_password" {
  description = "SQL Server sysadmin login password (sensitive)."
  value       = random_password.sql_admin.result
  sensitive   = true
}
