resource "random_integer" "num" {
  min = 10000
  max = 99999
}

data "azurerm_client_config" "current" {}

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
    azapi   = { source = "azure/azapi" }
  }
}

provider "azurerm" {
  # リソースプロバイダーの登録モード (core, extended, all, none, legacy)
  resource_provider_registrations = "none"

  features {
    key_vault {
      # Azure Key Vault の論理削除を無効にする
      purge_soft_delete_on_destroy = true
    }
    resource_group {
      # リソースグループ内にリソースがあっても削除する
      prevent_deletion_if_contains_resources = false
    }
  }
}

# ------------------------------------------------------------------------------------------------------
# Resource Group
# ------------------------------------------------------------------------------------------------------
resource "azurerm_resource_group" "main" {
  name     = "rg-${var.common.project}-${var.env}"
  location = var.common.location
}

# ------------------------------------------------------------------------------------------------------
# Virtual Network
# ------------------------------------------------------------------------------------------------------
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${var.common.project}-${var.env}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = var.vnet.address_space
  dns_servers         = var.vnet.dns_servers
}

resource "azurerm_subnet" "subnet" {
  for_each                          = var.subnet
  name                              = "snet-${each.value.name}"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.vnet.name
  address_prefixes                  = each.value.address_prefixes
  default_outbound_access_enabled   = each.value.default_outbound_access_enabled
  private_endpoint_network_policies = each.value.private_endpoint_network_policies
  service_endpoints                 = lookup(each.value, "service_endpoints", null) != null ? each.value.service_endpoints : null

  dynamic "delegation" {
    for_each = lookup(each.value, "service_delegation", null) != null ? [each.value.service_delegation] : []
    content {
      name = "delegation"
      service_delegation {
        name    = delegation.value.name
        actions = delegation.value.actions
      }
    }
  }
}

# ------------------------------------------------------------------------------------------------------
# Network Security Group
# ------------------------------------------------------------------------------------------------------
resource "azurerm_network_security_group" "nsg" {
  for_each            = var.network_security_group
  name                = "nsg-${each.value.name}-${var.common.project}-${var.env}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

# ------------------------------------------------------------------------------------------------------
# Private Endpoint
# ------------------------------------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "zone" {
  for_each            = var.private_dns_zone
  name                = each.value
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "link" {
  for_each              = var.private_dns_zone
  name                  = "vnetlink"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.zone[each.key].name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_private_endpoint" "pe" {
  for_each                      = local.private_endpoint
  name                          = "pe-${each.value.name}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  subnet_id                     = azurerm_subnet.subnet["pe"].id
  custom_network_interface_name = "pe-nic-${each.value.name}"

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = each.value.private_dns_zone_ids
  }

  private_service_connection {
    name                           = "connection"
    is_manual_connection           = false
    private_connection_resource_id = each.value.private_connection_resource_id
    subresource_names              = each.value.subresource_names
  }
}

# ------------------------------------------------------------------------------------------------------
# Azure Key Vault
# ------------------------------------------------------------------------------------------------------
resource "azurerm_key_vault" "kv" {
  name                          = "kv-${var.common.project}-${var.env}-${random_integer.num.result}"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  sku_name                      = var.key_vault.sku_name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  rbac_authorization_enabled    = var.key_vault.rbac_authorization_enabled
  purge_protection_enabled      = var.key_vault.purge_protection_enabled
  soft_delete_retention_days    = var.key_vault.soft_delete_retention_days
  public_network_access_enabled = var.key_vault.public_network_access_enabled
  access_policy                 = []

  network_acls {
    default_action             = var.key_vault.network_acls.default_action
    bypass                     = var.key_vault.network_acls.bypass
    ip_rules                   = var.allowed_cidr
    virtual_network_subnet_ids = var.key_vault.network_acls.virtual_network_subnet_ids
  }
}

# ------------------------------------------------------------------------------------------------------
# User Assigned Managed ID
# ------------------------------------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "id" {
  for_each            = var.user_assigned_identity
  name                = "id-${var.env}-${random_integer.num.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_role_assignment" "role" {
  for_each             = var.role_assignment
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${azurerm_resource_group.main.name}"
  role_definition_name = each.value.role_definition_name
  principal_id         = azurerm_user_assigned_identity.id[each.value.target_identity].principal_id
}

# ------------------------------------------------------------------------------------------------------
# Deployment Script
# ------------------------------------------------------------------------------------------------------
resource "azurerm_storage_account" "deploy_script" {
  name                     = "stds${var.common.project}${var.env}${random_integer.num.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  network_rules {
    bypass                     = ["AzureServices"]
    default_action             = "Deny"
    virtual_network_subnet_ids = [azurerm_subnet.subnet["ci"].id]
    ip_rules                   = var.allowed_cidr
  }
}

resource "azapi_resource" "keyvault_secret_set" {
  type      = "Microsoft.Resources/deploymentScripts@2023-08-01"
  name      = "keyvault_secret_set"
  parent_id = azurerm_resource_group.main.id
  body = {
    kind     = "AzureCLI"
    location = azurerm_resource_group.main.location
    identity = {
      type = "userAssigned"
      userAssignedIdentities = {
        (azurerm_user_assigned_identity.id["ci"].id) = {}
      }
    }
    properties = {
      azCliVersion      = "2.52.0"
      retentionInterval = "P1D"       # deploymentScript リソースを保持する期間
      cleanupPreference = "OnSuccess" # スクリプトの実行が終了状態になった時にサポートリソースをクリーンアップする方法 (Always, OnSuccess, OnExpiration)
      storageAccountSettings = {
        storageAccountName = azurerm_storage_account.deploy_script.name
      }
      containerSettings = {
        subnetIds = [
          { id = azurerm_subnet.subnet["ci"].id, name = azurerm_subnet.subnet["ci"].name }
        ]
      }
      scriptContent = <<EOF
        set -e
         az keyvault secret set --vault-name ${azurerm_key_vault.kv.name} --name MySecretName --value MySecretValue
        echo "seed done"
      EOF
    }
  }
}

# 2025/9 時点では azurerm プロバイダーではサブネットの指定ができない
# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_deployment_script_azure_cli
# resource "azurerm_resource_deployment_script_azure_cli" "deploy_script" {
#   name                = "keyvault_secret_set"
#   resource_group_name = azurerm_resource_group.main.name
#   location            = azurerm_resource_group.main.location
#   version             = "2.52.0"
#   retention_interval  = "P1D"
#   cleanup_preference  = "OnSuccess"
#   timeout             = "PT5M"

#   script_content = <<EOF
#     set -e
#       az keyvault secret set --vault-name ${azurerm_key_vault.kv.name} --name MySecretName --value MySecretValue
#     echo "seed done"
#   EOF

#   identity {
#     type = "UserAssigned"
#     identity_ids = [
#       azurerm_user_assigned_identity.id["ci"].id
#     ]
#   }
# }
