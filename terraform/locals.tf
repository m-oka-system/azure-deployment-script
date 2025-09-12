locals {
  # プライベートエンドポイント
  private_endpoint = {
    kv = {
      name                           = azurerm_key_vault.kv.name
      private_dns_zone_ids           = try([azurerm_private_dns_zone.zone["kv"].id], [])
      subresource_names              = ["vault"]
      private_connection_resource_id = azurerm_key_vault.kv.id
    }
  }
}
