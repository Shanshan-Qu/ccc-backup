# Non-production Linux VM
module "nonprod_vm" {
  source  = "Azure/avm-res-compute-virtualmachine/azurerm"
  version = "~> 0.15"

  name                = "vm-ccc-${var.workload}-${local.region_code}-${var.environment}-01"
  resource_group_name = module.resource_group.name
  location            = var.location
  os_type             = "Linux"
  sku_size            = "Standard_D2s_v5"
  tags                = local.tags

  zone = null # no zone preference; NZN has limited zone availability

  encryption_at_host_enabled = false # Microsoft.Compute/EncryptionAtHost not registered on this subscription

  account_credentials = {
    admin_credentials = {
      username                           = "cccadmin"
      ssh_keys                           = [tls_private_key.vm.public_key_openssh]
      generate_admin_password_or_ssh_key = false
    }
    password_authentication_disabled = true
  }

  source_image_reference = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk = {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  network_interfaces = {
    primary = {
      name = "nic-ccc-${var.workload}-${local.region_code}-${var.environment}-01"
      ip_configurations = {
        primary = {
          name                          = "internal"
          private_ip_address_allocation = "Dynamic"
          private_ip_subnet_resource_id = module.workload_vnet.subnets["workload"].resource_id
        }
      }
    }
  }

  custom_data = base64encode(<<-CLOUDINIT
    #!/bin/bash
    mkdir -p /opt/ccc-testdata
    echo "=== CCC Azure Backup Test Workload ===" > /opt/ccc-testdata/sample.txt
    echo "Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /opt/ccc-testdata/sample.txt
    for i in $(seq 1 100); do
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | Workload record $i | INFO | Simulated application log entry" >> /opt/ccc-testdata/workload.log
    done
    chmod -R 644 /opt/ccc-testdata/
    echo "CCC test data seeded at $(date -u)" >> /var/log/ccc-backup-init.log
  CLOUDINIT
  )

  depends_on = [module.resource_group, module.workload_vnet]
}

# SQL Server 2022 Developer on Windows Server 2022
module "sql_vm" {
  source  = "Azure/avm-res-compute-virtualmachine/azurerm"
  version = "~> 0.15"

  name                = "vm-ccc-sql-${local.region_code}-${var.environment}-01"
  resource_group_name = module.resource_group.name
  location            = var.location
  os_type             = "Windows"
  sku_size            = "Standard_D4s_v5"
  computer_name       = "ccc-sql-nzn01"
  tags                = local.tags

  zone = null

  encryption_at_host_enabled = false # Microsoft.Compute/EncryptionAtHost not registered on this subscription

  account_credentials = {
    admin_credentials = {
      username                           = "cccadmin"
      generate_admin_password_or_ssh_key = true
    }
  }

  source_image_reference = {
    publisher = "MicrosoftSQLServer"
    offer     = "sql2022-ws2022"
    sku       = "sqldev-gen2"
    version   = "latest"
  }

  os_disk = {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  network_interfaces = {
    primary = {
      name = "nic-ccc-sql-${local.region_code}-${var.environment}-01"
      ip_configurations = {
        primary = {
          name                          = "internal"
          private_ip_address_allocation = "Dynamic"
          private_ip_subnet_resource_id = module.workload_vnet.subnets["workload"].resource_id
        }
      }
    }
  }

  depends_on = [module.resource_group, module.workload_vnet]
}
