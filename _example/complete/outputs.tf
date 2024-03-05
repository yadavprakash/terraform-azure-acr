output "acr_id" {
  value       = module.container-registry.container_registry_id
  description = "The ID of the Container Registry"
}

output "acr_private_dns_zone" {
  value       = module.container-registry.container_registry_private_dns_zone
  description = "DNS zone name of Azure Container Registry Private endpoints dns name records"
}
