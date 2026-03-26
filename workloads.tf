resource "random_string" "storage_suffix" {
  length  = 5 # combined with stccc+region+env prefix gives a unique, recognisable name within 24 chars
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

# Azure File Share backup protection (shared key access now enabled — configured via Terraform)
resource "azurerm_backup_protected_file_share" "test_share" {
  resource_group_name       = module.resource_group.name
  recovery_vault_name       = module.recovery_services_vault.resource.name
  source_storage_account_id = module.files_storage.resource_id
  source_file_share_name    = azurerm_storage_share.test.name
  backup_policy_id          = module.recovery_services_vault.recovery_services_vault_file_share_policy["ccc-azfiles-policy"].resource_id

  depends_on = [azurerm_backup_container_storage_account.files, azurerm_storage_share.test]
}

# Non-prod Linux VM backup registration
resource "azurerm_backup_protected_vm" "nonprod" {
  resource_group_name = module.resource_group.name
  recovery_vault_name = module.recovery_services_vault.resource.name
  source_vm_id        = module.nonprod_vm.resource_id
  backup_policy_id    = module.recovery_services_vault.recovery_services_vault_vm_policy["ccc-vm-policy"].resource_id

  depends_on = [module.nonprod_vm]
}

# SQL IaaS extension — enables workload-level backup discovery in the vault
resource "azurerm_mssql_virtual_machine" "sql" {
  virtual_machine_id = module.sql_vm.resource_id
  sql_license_type   = "PAYG"

  depends_on = [module.sql_vm]
}
