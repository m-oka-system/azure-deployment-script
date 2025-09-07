variable "allowed_cidr" {
  type = list(string)
}

variable "common" {
  type = map(string)
  default = {
    project  = "scripts"
    location = "japaneast"
  }
}

variable "env" {
  type    = string
  default = "dev"
}

variable "vnet" {
  type = object({
    address_space = list(string)
    dns_servers   = list(string)
  })
  default = {
    address_space = ["10.10.0.0/16"]
    dns_servers   = [] # 既定の DNS を使用する場合は空のリストを指定
  }
}

variable "subnet" {
  type = map(object({
    name                              = string
    address_prefixes                  = list(string)
    default_outbound_access_enabled   = bool
    private_endpoint_network_policies = string
    service_delegation = object({
      name    = string
      actions = list(string)
    })
  }))
  default = {
    pe = {
      name                              = "pe"
      address_prefixes                  = ["10.10.0.0/24"]
      default_outbound_access_enabled   = false
      private_endpoint_network_policies = "Enabled"
      service_delegation                = null
    }
    ci = {
      name                              = "ci"
      address_prefixes                  = ["10.10.1.0/24"]
      default_outbound_access_enabled   = false
      private_endpoint_network_policies = "Disabled"
      service_delegation = {
        name    = "Microsoft.ContainerInstance/containerGroups"
        actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
      }
    }
    agw = {
      name                              = "agw"
      address_prefixes                  = ["10.10.2.0/24"]
      default_outbound_access_enabled   = false
      private_endpoint_network_policies = "Disabled"
      service_delegation = {
        name    = "Microsoft.Network/applicationGateways"
        actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      }
    }
    vm = {
      name                              = "vm"
      address_prefixes                  = ["10.10.3.0/24"]
      default_outbound_access_enabled   = false
      private_endpoint_network_policies = "Disabled"
      service_delegation                = null
    }
  }
}

variable "network_security_group" {
  type = map(object({
    name          = string
    target_subnet = string
  }))
  default = {
    pe = {
      name          = "pe"
      target_subnet = "pe"
    }
    ci = {
      name          = "ci"
      target_subnet = "ci"
    }
    agw = {
      name          = "agw"
      target_subnet = "agw"
    }
    vm = {
      name          = "vm"
      target_subnet = "vm"
    }
  }
}

variable "key_vault" {
  type = object({
    sku_name                      = string
    rbac_authorization_enabled    = bool
    purge_protection_enabled      = bool
    soft_delete_retention_days    = number
    public_network_access_enabled = bool
    network_acls = object({
      default_action             = string
      bypass                     = string
      virtual_network_subnet_ids = list(string)
    })
  })
  default = {
    sku_name                      = "standard"
    rbac_authorization_enabled    = true
    purge_protection_enabled      = false
    soft_delete_retention_days    = 7
    public_network_access_enabled = true
    network_acls = {
      default_action             = "Deny"
      bypass                     = "AzureServices"
      virtual_network_subnet_ids = []
    }
  }
}

variable "user_assigned_identity" {
  type = map(object({
    name = string
  }))
  default = {
    ci = {
      name = "ci"
    }
  }
}

variable "role_assignment" {
  type = map(object({
    target_identity      = string
    role_definition_name = string
  }))
  default = {
    ci_key_vault_secrets_officer = {
      target_identity      = "ci"
      role_definition_name = "Key Vault Secrets Officer"
    }
    ci_storage_file_data_privileged_contributor = {
      target_identity      = "ci"
      role_definition_name = "Storage File Data Privileged Contributor"
    }
  }
}

variable "private_dns_zone" {
  type = map(string)
  default = {
    kv = "privatelink.vaultcore.azure.net"
  }
}
