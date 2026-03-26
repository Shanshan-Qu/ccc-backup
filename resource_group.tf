module "resource_group" {
  source  = "Azure/avm-res-resources-resourcegroup/azurerm"
  version = "~> 0.2"

  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}
