locals {
  region_code = "nzn" # New Zealand North

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

  create_private_endpoint = var.private_endpoint_subnet_id != ""

  vault_private_endpoints = local.create_private_endpoint ? {
    "pe-${local.vault_name}" = {
      name                            = "pe-${local.vault_name}"
      subnet_resource_id              = var.private_endpoint_subnet_id
      subresource_name                = "AzureBackup"
      private_dns_zone_resource_ids   = toset(var.private_dns_zone_ids)
      private_service_connection_name = "psc-${local.vault_name}"
    }
  } : {}
}
