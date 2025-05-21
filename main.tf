# Configure the Azure provider
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0.2"
    }
  }

  required_version = ">= 1.1.0"
}

provider "azurerm" {
  features {}

  client_id       = var.azure_spn_client_id
  client_secret   = var.azure_spn_client_secret
  tenant_id       = var.azure_spn_tenant_id
  subscription_id = var.azure_spn_subscription_id
}

variable "image_registry_username" {
  type      = string
  sensitive = true
}

variable "image_registry_password" {
  type      = string
  sensitive = true
}

variable "azure_spn_client_id" {
  type      = string
  sensitive = true
}

variable "azure_spn_client_secret" {
  type      = string
  sensitive = true
}

variable "azure_spn_tenant_id" {
  type      = string
  sensitive = true
}

variable "azure_spn_subscription_id" {
  type      = string
  sensitive = true
}

# Define the resource group
resource "azurerm_resource_group" "rg" {
  name     = "2425-B2C6-B2B-2"
  location = "westeurope"
}

# Create the container registry
resource "azurerm_container_registry" "acr" {
  name                = "containerRegistryB2B"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true
}

# Creatre the container group where all the containers will be defined
resource "azurerm_container_group" "aci" {
  name                = "container_group_b2b"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  dns_name_label      = "containergroupaci"
  ip_address_type     = "Public"

  container {
    name   = "frontendapp"
    image  = "${azurerm_container_registry.acr.login_server}/b2b-frontend:latest"
    cpu    = "0.5"
    memory = "1.5"

    # Open ports of the container
    ports {
      port     = 3000
      protocol = "TCP"
    }
  }

  container {
    name   = "nginx"
    image  = "${azurerm_container_registry.acr.login_server}/b2b-nginx:latest"
    cpu    = "0.25"
    memory = "0.5"

    ports {
      port     = 80
      protocol = "TCP"
    }
  }

  image_registry_credential {
    server   = azurerm_container_registry.acr.login_server
    username = var.image_registry_username
    password = var.image_registry_password
  }
}