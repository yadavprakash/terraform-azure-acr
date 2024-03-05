provider "azurerm" {
  features {}
}

locals {
  name        = "app2"
  environment = "test"
}

##-----------------------------------------------------------------------------
## Resource Group module call
## Resource group in which all resources will be deployed.
##-----------------------------------------------------------------------------
module "resource_group" {
  source      = "git::https://github.com/opsstation/terraform-azure-resource-group.git?ref=v1.0.0"
  name        = "complete"
  environment = "tested"
  location    = "North Europe"
}

##-----------------------------------------------------------------------------
## Virtual Network module call.
## Virtual Network for which subnet will be created for private endpoint and vnet link will be created in private dns zone.
##-----------------------------------------------------------------------------
module "vnet" {
  source              = "git::https://github.com/opsstation/terraform-azure-vnet.git?ref=v1.0.0"
  name                = "app"
  environment         = "test"
  resource_group_name = module.resource_group.resource_group_name
  location            = module.resource_group.resource_group_location
  address_spaces      = ["10.0.0.0/16"]
}

##-----------------------------------------------------------------------------
## Subnet module call.
## Subnet in which private endpoint will be created.
##-----------------------------------------------------------------------------
module "subnet" {
  source = "git::https://github.com/opsstation/terraform-azure-subnet.git?ref=v1.0.1"

  name                 = "app"
  environment          = "test"
  resource_group_name  = module.resource_group.resource_group_name
  location             = module.resource_group.resource_group_location
  virtual_network_name = join("", module.vnet[*].vnet_name)
  #subnet
  subnet_names    = ["subnet1"]
  subnet_prefixes = ["10.0.1.0/24"]

  # route_table
  enable_route_table = true
  route_table_name   = "default_subnet"
  routes = [
    {
      name           = "rt-test"
      address_prefix = "0.0.0.0/0"
      next_hop_type  = "Internet"
    }
  ]
}

##--------------------------------------------------------------------------
##-----------------------------------------------------------------------------
## ACR module call.
##-----------------------------------------------------------------------------
module "container-registry" {
  source              = "../../"
  name                = local.name # Name used for specifying tags and other resources naming.(like private endpoint, vnet-link etc)
  environment         = local.environment
  resource_group_name = module.resource_group.resource_group_name
  location            = module.resource_group.resource_group_location
  container_registry_config = {
    name = "cdacr1234" # Name of Container Registry
    sku  = "Premium"
  }
  #  log_analytics_workspace_id = "module.log-analytics.workspace_id"
  ##-----------------------------------------------------------------------------
  ## To be mentioned for private endpoint, because private endpoint is enabled by default.
  ## To disable private endpoint set 'enable_private_endpoint' variable = false and than no need to specify following variable
  ##-----------------------------------------------------------------------------
  virtual_network_id = join("", module.vnet.vnet_id)
  subnet_id          = module.subnet.subnet_id
}
