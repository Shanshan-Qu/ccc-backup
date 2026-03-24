# State migration complete. These moved blocks can be removed after the next
# successful apply confirms all resources are tracked at their new addresses.

moved {
  from = azurerm_backup_policy_vm.vm_nonprod
  to   = module.recovery_services_vault.module.recovery_services_vault_vm_policy["ccc-policy"].azurerm_backup_policy_vm.this
}

moved {
  from = azurerm_backup_policy_file_share.azfiles
  to   = module.recovery_services_vault.module.recovery_services_vault_file_share_policy["ccc-azfiles-policy"].azurerm_backup_policy_file_share.this
}

moved {
  from = azurerm_backup_policy_vm_workload.sql
  to   = module.recovery_services_vault.module.recovery_workload_policy["ccc-sqlpolicy"].azurerm_backup_policy_vm_workload.this[0]
}


moved {
  from = azurerm_network_security_group.workload
  to   = module.workload_nsg.azurerm_network_security_group.this
}


moved {
  from = azurerm_storage_account.files
  to   = module.files_storage.azurerm_storage_account.this
}

moved {
  from = azurerm_role_assignment.vault_backup_storage
  to   = module.files_storage.azurerm_role_assignment.storage_account["vault_backup_contributor"]
}

moved {
  from = azurerm_role_assignment.bms_backup_storage
  to   = module.files_storage.azurerm_role_assignment.storage_account["bms_backup_contributor"]
}


moved {
  from = azurerm_network_interface.vm
  to   = module.nonprod_vm.azurerm_network_interface.virtualmachine_network_interfaces["primary"]
}


moved {
  from = azurerm_linux_virtual_machine.nonprod
  to   = module.nonprod_vm.azurerm_linux_virtual_machine.this[0]
}

# ── SQL Server VM NIC ───────────────────────────────────────

moved {
  from = azurerm_network_interface.sql_vm
  to   = module.sql_vm.azurerm_network_interface.virtualmachine_network_interfaces["primary"]
}


moved {
  from = azurerm_windows_virtual_machine.sql
  to   = module.sql_vm.azurerm_windows_virtual_machine.this[0]
}
