module "log_analytics_workspace" {
  source  = "Azure/avm-res-operationalinsights-workspace/azurerm"
  version = "~> 0.4"

  name                = local.law_name
  location            = var.location
  resource_group_name = module.resource_group.name

  log_analytics_workspace_retention_in_days = var.log_analytics_retention_days

  tags = local.tags

  depends_on = [module.resource_group]
}
