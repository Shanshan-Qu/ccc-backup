resource "random_string" "storage_suffix" {
  length  = 8
  special = false
  upper   = false
  numeric = true
}

resource "tls_private_key" "vm" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Azure Files backup container
resource "azurerm_backup_container_storage_account" "files" {
  resource_group_name = module.resource_group.name
  recovery_vault_name = module.recovery_services_vault.resource.name
  storage_account_id  = module.files_storage.resource_id

  depends_on = [module.files_storage]
}

# Azure Files protection must be configured via the Portal:
# Vault -> Backup -> Azure File Share -> select storage account -> assign CCC-AzFiles-Policy
# (azurerm_backup_protected_file_share requires shared key access which is disabled)

# Non-prod Linux VM backup registration
resource "azurerm_backup_protected_vm" "nonprod" {
  resource_group_name = module.resource_group.name
  recovery_vault_name = module.recovery_services_vault.resource.name
  source_vm_id        = module.nonprod_vm.resource_id
  backup_policy_id    = module.recovery_services_vault.recovery_services_vault_vm_policy["ccc-policy"].resource_id

  depends_on = [module.nonprod_vm]
}

# SQL IaaS extension — enables workload-level backup discovery
# After VM boots, register the container:
#   az backup container register \
#     --resource-group rg-rsv-backup-nzn \
#     --vault-name rsv-ccc-backup-nzn-test \
#     --backup-management-type AzureWorkload \
#     --workload-type SQLDataBase \
#     --resource-id $(terraform output -raw sql_vm_id)
resource "azurerm_mssql_virtual_machine" "sql" {
  virtual_machine_id = module.sql_vm.resource_id
  sql_license_type   = "PAYG"

  depends_on = [module.sql_vm]
}
