# Current deployer identity — used to grant file-data RBAC so the test script can upload files
# (storage_use_azuread = true in the provider forces allow_shared_key_access = false,
#  so OAuth RBAC is the only way to upload files from scripts)
data "azurerm_client_config" "current" {}

module "files_storage" {
  source  = "Azure/avm-res-storage-storageaccount/azurerm"
  version = "~> 0.2"

  name                            = "stccc${local.region_code}${local.env_short}${random_string.storage_suffix.result}"
  resource_group_name             = module.resource_group.name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true  # shared-key constraint lifted on this subscription
  public_network_access_enabled   = true  # allow test script uploads from client machine
  # Allow all public traffic so test scripts can upload files; AzureBackup RBAC enforces access
  network_rules = {
    default_action = "Allow"
    bypass         = ["AzureServices"]
  }
  tags = local.tags

  role_assignments = {
    vault_backup_contributor = {
      role_definition_id_or_name = "Storage Account Backup Contributor"
      principal_id               = module.recovery_services_vault.resource.identity[0].principal_id
    }
    bms_backup_contributor = {
      role_definition_id_or_name = "Storage Account Backup Contributor"
      principal_id               = "1de5ba0f-6130-42ed-8bcf-1f5ecca84aec" # Backup Management Service SPN
    }
    current_user_file_contributor = {
      role_definition_id_or_name = "Storage File Data Privileged Contributor"
      principal_id               = data.azurerm_client_config.current.object_id
    }
  }

  depends_on = [module.resource_group, module.recovery_services_vault]
}
