
module "labels" {
  source      = "git::https://github.com/yadavprakash/terraform-azure-labels.git?ref=v1.0.0"
  name        = var.name
  environment = var.environment
  managedby   = var.managedby
  label_order = var.label_order
  repository  = var.repository
}

resource "azurerm_container_registry" "main" {
  count                         = var.enable ? 1 : 0
  name                          = var.container_registry_config.name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  admin_enabled                 = var.admin_enabled
  sku                           = var.container_registry_config.sku
  public_network_access_enabled = var.public_network_access_enabled
  quarantine_policy_enabled     = var.container_registry_config.quarantine_policy_enabled
  zone_redundancy_enabled       = var.container_registry_config.zone_redundancy_enabled
  tags                          = module.labels.tags

  dynamic "georeplications" {
    for_each = var.georeplications
    content {
      location                = georeplications.value.location
      zone_redundancy_enabled = georeplications.value.zone_redundancy_enabled
      tags                    = merge({ "Name" = format("%s", "georep-${georeplications.value.location}") }, module.labels.tags, )
    }
  }


  dynamic "network_rule_set" {
    for_each = var.network_rule_set != null ? [var.network_rule_set] : []
    content {
      default_action = lookup(network_rule_set.value, "default_action", "Allow")

      dynamic "ip_rule" {
        for_each = network_rule_set.value.ip_rule
        content {
          action   = "Allow"
          ip_range = ip_rule.value.ip_range
        }
      }

      dynamic "virtual_network" {
        for_each = network_rule_set.value.virtual_network
        content {
          action    = "Allow"
          subnet_id = virtual_network.value.subnet_id
        }
      }
    }
  }

  dynamic "retention_policy" {
    for_each = var.retention_policy != null ? [var.retention_policy] : []
    content {
      days    = lookup(retention_policy.value, "days", 7)
      enabled = lookup(retention_policy.value, "enabled", true)
    }
  }

  dynamic "trust_policy" {
    for_each = var.enable_content_trust ? [1] : []
    content {
      enabled = var.enable_content_trust
    }
  }

  identity {
    type         = var.identity_ids != null ? "SystemAssigned, UserAssigned" : "SystemAssigned"
    identity_ids = var.identity_ids
  }

  dynamic "encryption" {
    for_each = var.encryption != null ? [var.encryption] : []
    content {
      enabled            = true
      key_vault_key_id   = encryption.value.key_vault_key_id
      identity_client_id = encryption.value.identity_client_id
    }
  }
}


resource "azurerm_container_registry_scope_map" "main" {
  for_each                = var.scope_map != null ? { for k, v in var.scope_map : k => v if v != null } : {}
  name                    = format("%s", each.key)
  resource_group_name     = var.resource_group_name
  container_registry_name = azurerm_container_registry.main[*].name
  actions                 = each.value["actions"]
}


resource "azurerm_container_registry_token" "main" {
  for_each                = var.scope_map != null ? { for k, v in var.scope_map : k => v if v != null } : {}
  name                    = format("%s", "${each.key}-token")
  resource_group_name     = var.resource_group_name
  container_registry_name = azurerm_container_registry.main[*].name
  scope_map_id            = element([for k in azurerm_container_registry_scope_map.main : k.id], 0)
  enabled                 = true
}

resource "azurerm_container_registry_webhook" "webhook" {
  for_each            = var.container_registry_webhooks != null ? { for k, v in var.container_registry_webhooks : k => v if v != null } : {}
  name                = format("%s", each.key)
  resource_group_name = var.resource_group_name
  location            = var.location
  registry_name       = azurerm_container_registry.main[*].name
  service_uri         = each.value["service_uri"]
  actions             = each.value["actions"]
  status              = each.value["status"]
  scope               = each.value["scope"]
  custom_headers      = each.value["custom_headers"]
  lifecycle {
    ignore_changes = [
      tags
    ]
  }
}

resource "azurerm_private_endpoint" "pep" {
  count               = var.enable && var.enable_private_endpoint ? 1 : 0
  name                = format("%s-%s-pep-acr", var.container_registry_config.name, module.labels.id)
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = join("", var.subnet_id)
  private_dns_zone_group {
    name                 = format("%s-%s-acr", var.container_registry_config.name, "dns-zone-group")
    private_dns_zone_ids = var.existing_private_dns_zone == null ? [azurerm_private_dns_zone.dnszone[0].id] : [var.existing_private_dns_zone_id]
  }
  private_service_connection {
    name                           = format("%s-%s-acr", var.container_registry_config.name, "private-link")
    is_manual_connection           = false
    private_connection_resource_id = azurerm_container_registry.main[0].id
    subresource_names              = ["registry"]
  }
  lifecycle {
    ignore_changes = [
      tags,
    ]
  }
}

provider "azurerm" {
  alias = "peer"
  features {}
  subscription_id = var.alias_sub
}

locals {
  valid_rg_name         = var.existing_private_dns_zone == null ? var.resource_group_name : var.existing_private_dns_zone_resource_group_name
  private_dns_zone_name = var.existing_private_dns_zone == null ? join("", azurerm_private_dns_zone.dnszone[*].name) : var.existing_private_dns_zone
}


resource "azurerm_private_dns_zone" "dnszone" {
  count               = var.enable && var.existing_private_dns_zone == null && var.enable_private_endpoint ? 1 : 0
  name                = var.private_dns_name
  resource_group_name = var.resource_group_name
  tags                = module.labels.tags
}


resource "azurerm_private_dns_zone_virtual_network_link" "vent-link-same-sub" {
  count                 = var.enable && var.enable_private_endpoint && var.diff_sub == false && var.same_vnet == false ? 1 : 0
  name                  = var.existing_private_dns_zone == null ? format("%s-pdz-vnet-link-acr", module.labels.id) : format("%s-pdz-vnet-link-acr-1", module.labels.id)
  resource_group_name   = local.valid_rg_name
  private_dns_zone_name = local.private_dns_zone_name
  virtual_network_id    = var.virtual_network_id
  registration_enabled  = var.private_dns_zone_vnet_link_registration_enabled
  tags                  = module.labels.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "vent-link-diff_sub" {
  provider              = azurerm.peer
  count                 = var.enable && var.enable_private_endpoint && var.diff_sub == true ? 1 : 0
  name                  = var.existing_private_dns_zone == null ? format("%s-pdz-vnet-link-acr", module.labels.id) : format("%s-pdz-vnet-link-acr-1", module.labels.id)
  resource_group_name   = local.valid_rg_name
  private_dns_zone_name = local.private_dns_zone_name
  virtual_network_id    = var.virtual_network_id
  tags                  = module.labels.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "vent-link-multi-subs" {
  provider              = azurerm.peer
  count                 = var.multi_sub_vnet_link && var.existing_private_dns_zone != null ? 1 : 0
  name                  = format("%s-pdz-vnet-link-acr-1", module.labels.id)
  resource_group_name   = var.existing_private_dns_zone_resource_group_name
  private_dns_zone_name = var.existing_private_dns_zone
  virtual_network_id    = var.virtual_network_id
  tags                  = module.labels.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "addon_vent_link" {
  count                 = var.enable && var.addon_vent_link ? 1 : 0
  name                  = format("%s-pdz-vnet-link-acr-addon", module.labels.id)
  resource_group_name   = var.existing_private_dns_zone_resource_group_name
  private_dns_zone_name = var.existing_private_dns_zone == null ? join("", azurerm_private_dns_zone.dnszone[*].name) : var.existing_private_dns_zone
  virtual_network_id    = var.addon_virtual_network_id
  tags                  = module.labels.tags
}