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

variable "ssl_cert" {
  type      = string
  sensitive = true
}

variable "ssl_cert_password" {
  type      = string
  sensitive = true
}

# Data source to get current subscription ID
data "azurerm_subscription" "current" {}

# Define the resource group
resource "azurerm_resource_group" "rg" {
  name     = "2425-B2C6-B2B-2"
  location = "westeurope"
}

resource "azurerm_public_ip" "appgw_ip" {
  name                = "appgw-public-ip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "b2b2buildingblocks"
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
}

# Create virtual network for frontend
resource "azurerm_subnet" "frontend" {
  name                 = "frontend-subnet"
  virtual_network_name = azurerm_virtual_network.vnet.name
  resource_group_name  = azurerm_resource_group.rg.name
  address_prefixes     = ["10.0.1.0/29"] # /29 is the highest subnetmask allowed by Azure this only has 3 ip-address that can be used (the rest is used by Azure)

  delegation {
    name = "aci-delegation"

    service_delegation {
      name = "Microsoft.ContainerInstance/containerGroups"

      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action",
      ]
    }
  }
}

# Create virtual network for backend
resource "azurerm_subnet" "backend" {
  name                 = "backend-subnet"
  virtual_network_name = azurerm_virtual_network.vnet.name
  resource_group_name  = azurerm_resource_group.rg.name
  address_prefixes     = ["10.0.2.0/29"]

  delegation {
    name = "aci-delegation"

    service_delegation {
      name = "Microsoft.ContainerInstance/containerGroups"

      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action",
      ]
    }
  }
}

# Create a dedicated subnet for the Application Gateway
resource "azurerm_subnet" "appgw_subnet" {
  name                 = "appgw-subnet"
  virtual_network_name = azurerm_virtual_network.vnet.name
  resource_group_name  = azurerm_resource_group.rg.name
  address_prefixes     = ["10.0.3.0/24"]
}

# Create an Application Gateway for routing public traffic to the correct subnet
resource "azurerm_application_gateway" "appgw" {
  name                = "appgateway"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1
  }

  gateway_ip_configuration {
    name      = "gateway-ip-config"
    subnet_id = azurerm_subnet.appgw_subnet.id
  }

  frontend_port {
    name = "frontend-port-80"
    port = 80
  }

  frontend_port {
    name = "frontend-port-443"
    port = 443
  }

  frontend_ip_configuration {
    name                 = "frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw_ip.id
  }

  backend_address_pool {
    name         = "frontend-pool"
    ip_addresses = ["10.0.1.4"]
  }

  backend_address_pool {
    name         = "backend-pool"
    ip_addresses = ["10.0.2.4"]
  }

  backend_http_settings {
    name                  = "http-settings-3000"
    port                  = 3000
    protocol              = "Http"
    cookie_based_affinity = "Disabled"
    request_timeout       = 30
  }

  redirect_configuration {
    name                 = "http-to-https-redirect"
    redirect_type        = "Permanent"
    target_listener_name = "https-listener"
    include_path         = true
    include_query_string = true
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "frontend-ip"
    frontend_port_name             = "frontend-port-80"
    protocol                       = "Http"
  }

  http_listener {
    name                           = "https-listener"
    frontend_ip_configuration_name = "frontend-ip"
    frontend_port_name             = "frontend-port-443"
    protocol                       = "Https"
    ssl_certificate_name           = "ssl-cert"
  }

  ssl_certificate {
    name     = "ssl-cert"
    data     = var.ssl_cert
    password = var.ssl_cert_password
  }

  request_routing_rule {
    name                        = "rule-80"
    rule_type                   = "Basic"
    http_listener_name          = "http-listener"
    redirect_configuration_name = "http-to-https-redirect"
  }

  request_routing_rule {
    name                       = "rule-443"
    rule_type                  = "Basic"
    http_listener_name         = "https-listener"
    backend_address_pool_name  = "frontend-pool"
    backend_http_settings_name = "http-settings-3000"
  }
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

# Create the Logic App workflow (basic skeleton)
resource "azurerm_logic_app_workflow" "webhook_handler" {
  name                = "acr-webhook-handler"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  identity {
    type = "SystemAssigned"
  }
}

# Create the webhook trigger
resource "azurerm_logic_app_trigger_http_request" "webhook_trigger" {
  name         = "manual"
  logic_app_id = azurerm_logic_app_workflow.webhook_handler.id

  schema = jsonencode({
    "type" = "array",
    "items" = {
      "type" = "object",
      "properties" = {
        "topic"     = { "type" = "string" },
        "subject"   = { "type" = "string" },
        "eventType" = { "type" = "string" },
        "eventTime" = { "type" = "string" },
        "id"        = { "type" = "string" },
        "data" = {
          "type" = "object",
          "properties" = {
            "target" = {
              "type" = "object",
              "properties" = {
                "repository" = { "type" = "string" },
                "tag"        = { "type" = "string" }
              }
            }
          }
        }
      }
    }
  })
}

# Create a condition action
resource "azurerm_logic_app_action_custom" "condition" {
  name         = "Condition"
  logic_app_id = azurerm_logic_app_workflow.webhook_handler.id

  body = jsonencode({
    "type" = "If",
    "expression" = {
      "and" = [
        {
          "contains" = [
            "@triggerBody()?[0]?['data']?['target']?['repository']",
            "b2b-frontend"
          ]
        }
      ]
    },
    "actions" = {
      "Restart_Frontend_Container" = {
        "type" = "Http",
        "inputs" = {
          "method" = "POST",
          "uri"    = "https://management.azure.com/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${azurerm_resource_group.rg.name}/providers/Microsoft.ContainerInstance/containerGroups/${azurerm_container_group.aci-frontend.name}/restart?api-version=2023-05-01",
          "authentication" = {
            "type" = "ManagedServiceIdentity"
          }
        }
      }
    },
    "runAfter" = {},
    "else" = {
      "actions" = {
        "Restart_Backend_Container" = {
          "type" = "Http",
          "inputs" = {
            "method" = "POST",
            "uri"    = "https://management.azure.com/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${azurerm_resource_group.rg.name}/providers/Microsoft.ContainerInstance/containerGroups/${azurerm_container_group.aci-backend.name}/restart?api-version=2023-05-01",
            "authentication" = {
              "type" = "ManagedServiceIdentity"
            }
          }
        }
      }
    }
  })
}

# Create an Event Grid System Topic for ACR events
resource "azurerm_eventgrid_system_topic" "acr_events" {
  name                   = "acr-events"
  resource_group_name    = azurerm_resource_group.rg.name
  location               = azurerm_resource_group.rg.location
  source_arm_resource_id = azurerm_container_registry.acr.id
  topic_type             = "Microsoft.ContainerRegistry.Registries"
}

# Create an Event Grid subscription to the Logic App
resource "azurerm_eventgrid_system_topic_event_subscription" "logic_app_subscription" {
  name                = "logic-app-subscription"
  system_topic        = azurerm_eventgrid_system_topic.acr_events.name
  resource_group_name = azurerm_resource_group.rg.name

  webhook_endpoint {
    url = "${azurerm_logic_app_workflow.webhook_handler.access_endpoint}/triggers/manual/run?api-version=2016-10-01"
  }

  included_event_types = ["Microsoft.ContainerRegistry.ImagePushed"]

  # Filter to match your repositories
  advanced_filter {
    string_contains {
      key    = "data.target.repository"
      values = ["b2b-frontend"]
    }
  }
}

# Create a second subscription for backend images
resource "azurerm_eventgrid_system_topic_event_subscription" "logic_app_subscription_backend" {
  name                = "logic-app-subscription-backend"
  system_topic        = azurerm_eventgrid_system_topic.acr_events.name
  resource_group_name = azurerm_resource_group.rg.name

  webhook_endpoint {
    url = "${azurerm_logic_app_workflow.webhook_handler.access_endpoint}/triggers/manual/run?api-version=2016-10-01"
  }

  included_event_types = ["Microsoft.ContainerRegistry.ImagePushed"]

  # Filter for backend repositories
  advanced_filter {
    string_contains {
      key    = "data.target.repository"
      values = ["b2b-api", "b2b-backend"]
    }
  }
}