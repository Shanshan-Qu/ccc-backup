locals {
  # --------------------------------------------------------
  # Naming  –  follows CCC pattern: <type>-ccc-<workload>-<region_code>[-<env>]
  # Region code "nzn" = New Zealand North
  # --------------------------------------------------------
  region_code = "nzn"

  resource_group_name = "rg-rsv-backup-${local.region_code}"            # as spec: rg-rsv-backup-nzn
  vault_name          = "rsv-ccc-${var.workload}-${local.region_code}-${var.environment}"
  law_name            = "law-ccc-${var.workload}-${local.region_code}-${var.environment}"
  action_group_ops    = "ag-backup-ops-${local.region_code}-${var.environment}"
  action_group_sec    = "ag-backup-sec-${local.region_code}-${var.environment}"

  # --------------------------------------------------------
  # Timezone –  NZST  (New Zealand Standard Time = UTC+12)
  #             Azure uses Windows timezone identifiers
  # --------------------------------------------------------
  nz_timezone = "New Zealand Standard Time"

  # --------------------------------------------------------
  # Default tags applied to every resource
  # --------------------------------------------------------
  default_tags = {
    environment   = var.environment
    workload      = var.workload
    managed_by    = "terraform"
    customer      = "ChristchurchCityCouncil"
    specification = "AzureBackupBuildSpec"
  }
  tags = merge(local.default_tags, var.tags)

  # --------------------------------------------------------
  # RBAC – build a flat role_assignments map for the vault
  # AVM expects: { "<unique_key>" = { role_definition_id_or_name, principal_id } }
  # --------------------------------------------------------
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

  # --------------------------------------------------------
  # Private endpoint  –  only create if subnet_id is provided
  # --------------------------------------------------------
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
