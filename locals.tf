locals {
  region_code = "nzn" # New Zealand North

  # Abbreviated environment label (max 3 chars) used where name-length is tight,
  # e.g. storage account names (24-char limit) and Windows computer names (15-char limit).
  env_short = substr(var.environment, 0, 3)

  # Windows NetBIOS computer name: max 15 chars.
  # "ccc-sql-nzn-tst" = 15 chars for environment="test".
  sql_computer_name = "ccc-sql-${local.region_code}-${local.env_short}"

  resource_group_name = "rg-rsv-backup-${local.region_code}"
  vault_name          = "rsv-ccc-${var.workload}-${local.region_code}-${var.environment}"
  law_name            = "law-ccc-${var.workload}-${local.region_code}-${var.environment}"
  action_group_ops    = "ag-backup-ops-${local.region_code}-${var.environment}"
  action_group_sec    = "ag-backup-sec-${local.region_code}-${var.environment}"

  nz_timezone = "New Zealand Standard Time"

  default_tags = {
    environment   = var.environment
    workload      = var.workload
    managed_by    = "terraform"
    customer      = "ChristchurchCityCouncil"
    specification = "AzureBackupBuildSpec"
  }
  tags = merge(local.default_tags, var.tags)

  _backup_contributor_assignments = {
    for idx, principal_id in var.backup_contributor_principal_ids :
    "backup_contributor_${idx}" => {
      role_definition_id_or_name = "Backup Contributor"
      principal_id               = principal_id
    }
  }
  _backup_operator_assignments = {
    for idx, principal_id in var.backup_operator_principal_ids :
    "backup_operator_${idx}" => {
      role_definition_id_or_name = "Backup Operator"
      principal_id               = principal_id
    }
  }
  _backup_reader_assignments = {
    for idx, principal_id in var.backup_reader_principal_ids :
    "backup_reader_${idx}" => {
      role_definition_id_or_name = "Backup Reader"
      principal_id               = principal_id
    }
  }
  _rsv_contributor_assignments = {
    for idx, principal_id in var.rsv_contributor_principal_ids :
    "rsv_contributor_${idx}" => {
      role_definition_id_or_name = "Site Recovery Contributor"
      principal_id               = principal_id
    }
  }

  vault_role_assignments = merge(
    local._backup_contributor_assignments,
    local._backup_operator_assignments,
    local._backup_reader_assignments,
    local._rsv_contributor_assignments,
  )

  # Private endpoint: always enabled per spec (public access disabled)
  vault_private_endpoints = {
    "pe-${local.vault_name}" = {
      name                            = "pe-${local.vault_name}"
      subnet_resource_id              = module.workload_vnet.subnets["private_endpoints"].resource_id
      subresource_name                = "AzureBackup"
      private_dns_zone_resource_ids   = toset([
        azurerm_private_dns_zone.backup.id,
        azurerm_private_dns_zone.backup_queue.id,
        azurerm_private_dns_zone.backup_blob.id,
      ])
      private_service_connection_name = "psc-${local.vault_name}"
    }
  }
}
