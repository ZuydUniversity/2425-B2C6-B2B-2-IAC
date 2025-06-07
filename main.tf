# Configure the Azure provider
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0.2"
    }
  }

  backend "azurerm" {}

  required_version = ">= 1.1.0"
}

provider "azurerm" {
  features {}
}

variable "image_registry_username" {
  type      = string
  sensitive = true
}

variable "image_registry_password" {
  type      = string
  sensitive = true
}

# Define the resource group
resource "azurerm_resource_group" "rg" {
  name     = "2425-B2C6-B2B-2"
  location = "westeurope"
}

# Create a security group
resource "azurerm_network_security_group" "nsg" {
  name                = "network-security-group"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# Create a virtual network
resource "azurerm_virtual_network" "vnet" {
  name                = "virtual-network"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    environment = "Production"
  }
}

# Create virtual network for frontend
resource "azurerm_subnet" "frontend" {
  name                 = "frontend-subnet"
  virtual_network_name = azurerm_virtual_network.vnet.name
  resource_group_name  = azurerm_resource_group.rg.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Create virtual network for backend
resource "azurerm_subnet" "backend" {
  name                 = "backend-subnet"
  virtual_network_name = azurerm_virtual_network.vnet.name
  resource_group_name  = azurerm_resource_group.rg.name
  address_prefixes     = ["10.0.2.0/24"]
}

# Create a network profile for connecting endpoints to the subnet
resource "azurerm_network_profile" "np-frontend" {
  name                = "network-profile-frontend"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  container_network_interface {
    name = "frontend-nic"
    ip_configuration {
      name      = "frontend-ip-config"
      subnet_id = azurerm_subnet.frontend.id
    }
  }
}

# Same as above but then for backend
resource "azurerm_network_profile" "np-backend" {
  name                = "network-profile-backend"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  container_network_interface {
    name = "backend-nic"
    ip_configuration {
      name      = "backend-ip-config"
      subnet_id = azurerm_subnet.backend.id
    }
  }
}

# Create the container registry
resource "azurerm_container_registry" "acr" {
  name                = "containerRegistryB2B"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true
}

# Create a container group for hosting containers for the frontend services
resource "azurerm_container_group" "aci-frontend" {
  name                = "container_group_frontend_b2b"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  ip_address_type     = "Private"
  network_profile_id  = azurerm_network_profile.np-frontend.id

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

    ports {
      port     = 443
      protocol = "TCP"
    }
  }

  image_registry_credential {
    server   = azurerm_container_registry.acr.login_server
    username = var.image_registry_username
    password = var.image_registry_password
  }
}

# Container group for the backend services (still need to change the database and API image.)
resource "azurerm_container_group" "aci-backend" {
  name                = "container_group_backend_b2b"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  ip_address_type     = "Private"
  network_profile_id  = azurerm_network_profile.np-backend.id

  container {
    name   = "backend-db"
    image  = "${azurerm_container_registry.acr.login_server}/b2b-backend:latest"
    cpu    = "0.5"
    memory = "1.5"

    ports {
      port     = 22
      protocol = "TCP"
    }
  }

  image_registry_credential {
    server   = azurerm_container_registry.acr.login_server
    username = var.image_registry_username
    password = var.image_registry_password
  }
}