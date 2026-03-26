module "workload_vnet" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "~> 0.7"

  name          = "vnet-ccc-${var.workload}-${local.region_code}-${var.environment}"
  location      = var.location
  parent_id     = module.resource_group.resource_id
  address_space = ["10.100.0.0/16"]
  tags          = local.tags

  subnets = {
    workload = {
      name             = "snet-workload-${local.region_code}"
      address_prefixes = ["10.100.1.0/24"]
      network_security_group = {
        id = module.workload_nsg.resource_id
      }
    }
  }

  depends_on = [module.resource_group, module.workload_nsg]
}

resource "azurerm_storage_share" "test" {
  name               = "ccc-test-share"
  storage_account_id = module.files_storage.resource_id
  quota              = 5
}
