import {
  to = module.workload_nsg.azurerm_network_security_rule.this["AllowAzureBackupOut"]
  id = "/subscriptions/634c603a-fa54-431f-8fdd-2279020b1cb9/resourceGroups/rg-rsv-backup-nzn/providers/Microsoft.Network/networkSecurityGroups/nsg-workload-nzn-test/securityRules/AllowAzureBackupOut"
}

import {
  to = module.workload_nsg.azurerm_network_security_rule.this["AllowStorageOut"]
  id = "/subscriptions/634c603a-fa54-431f-8fdd-2279020b1cb9/resourceGroups/rg-rsv-backup-nzn/providers/Microsoft.Network/networkSecurityGroups/nsg-workload-nzn-test/securityRules/AllowStorageOut"
}

import {
  to = module.workload_nsg.azurerm_network_security_rule.this["AllowAzureADOut"]
  id = "/subscriptions/634c603a-fa54-431f-8fdd-2279020b1cb9/resourceGroups/rg-rsv-backup-nzn/providers/Microsoft.Network/networkSecurityGroups/nsg-workload-nzn-test/securityRules/AllowAzureADOut"
}
