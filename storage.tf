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
  shared_access_key_enabled       = true  # shared-key constraint lifted on this subscription
  tags                            = local.tags

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
