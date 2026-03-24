# VNet and Subnet are kept as raw resources.
# The VNet AVM >= 0.7 uses azapi_resource internally, making a moved-block
# migration from an existing azurerm_virtual_network impossible without
# destroying live VM connectivity.

resource "azurerm_virtual_network" "workload" {
  name                = "vnet-ccc-${var.workload}-${local.region_code}-${var.environment}"
  location            = var.location
  resource_group_name = module.resource_group.name
  address_space       = ["10.100.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "workload" {
  name                 = "snet-workload-${local.region_code}"
  resource_group_name  = module.resource_group.name
  virtual_network_name = azurerm_virtual_network.workload.name
  address_prefixes     = ["10.100.1.0/24"]
}

resource "azurerm_subnet_network_security_group_association" "workload" {
  subnet_id                 = azurerm_subnet.workload.id
  network_security_group_id = module.workload_nsg.resource_id
}

# File share is kept as a raw resource: the storage AVM >= 0.4 uses
# azapi_resource for shares, incompatible with the existing state entry.
resource "azurerm_storage_share" "test" {
  name               = "ccc-test-share"
  storage_account_id = module.files_storage.resource_id
  quota              = 5
}
