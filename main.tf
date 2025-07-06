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

variable "sql_sa_password" {
  type      = string
  sensitive = true
}

variable "supabase_anon_key" {
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
resource "azurerm_network_security_group" "backend-nsg" {
  name                = "backend-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "AllowFrontendToAPI"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"        # API port
    source_address_prefix      = "10.0.1.0/29" # FROM frontend IP-addresses
    destination_address_prefix = "10.0.2.0/29" # TO backend IP-addresses
  }

  # Temporary rule to test if the API is accessible
  security_rule {
    name                       = "AllowPublicToApiTEMP"
    priority                   = 105
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"        # HTTP port used by API
    source_address_prefix      = "10.0.3.0/24" # Gateway subnet
    destination_address_prefix = "10.0.2.0/29" # Backend subnet
  }
}

# Connect the security group to the backend subnet
resource "azurerm_subnet_network_security_group_association" "backend_nsg_assoc" {
  subnet_id                 = azurerm_subnet.backend.id
  network_security_group_id = azurerm_network_security_group.backend-nsg.id
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

  # Temporary port to test the API
  frontend_port {
    name = "frontend-port-8080"
    port = 8080
  }

  frontend_ip_configuration {
    name                 = "frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw_ip.id
  }

  backend_address_pool {
    name         = "frontend-pool"
    ip_addresses = ["10.0.1.4", "10.0.1.5", "10.0.1.6"]
  }

  backend_address_pool {
    name         = "backend-pool"
    ip_addresses = ["10.0.2.4", "10.0.2.5", "10.0.2.6"]
  }

  # Add a health probe for  the API (temporary)
  probe {
    name                = "api-probe"
    protocol            = "Http"
    path                = "/api/Orders"
    interval            = 30
    timeout             = 30
    unhealthy_threshold = 3
    port                = 8080

    match {
      status_code = ["200-599"] # Accept any response as valid
      body        = ""          # Don't validate response body
    }
  }

  backend_http_settings {
    name                  = "http-settings-3000"
    port                  = 3000
    protocol              = "Http"
    cookie_based_affinity = "Disabled"
    request_timeout       = 30
  }

  # Temporary to test API
  backend_http_settings {
    name                  = "http-settings-8080"
    port                  = 8080
    protocol              = "Http"
    cookie_based_affinity = "Disabled"
    request_timeout       = 30
    probe_name            = "api-probe"
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

  # Temporary to test API
  http_listener {
    name                           = "api-listener"
    frontend_ip_configuration_name = "frontend-ip"
    frontend_port_name             = "frontend-port-8080"
    protocol                       = "Http"
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

  # Temporary to test API
  request_routing_rule {
    name                       = "rule-8080"
    rule_type                  = "Basic"
    http_listener_name         = "api-listener"
    backend_address_pool_name  = "backend-pool"
    backend_http_settings_name = "http-settings-8080"
  }
}

# Create a network profile for connecting the frontend container group to the subnet
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

# Create a storage account for the sqlserver databases
resource "azurerm_storage_account" "storage" {
  name                     = "b2b2ssqlstorage"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Createa a share for the sqlserver storage account
resource "azurerm_storage_share" "fileshare" {
  name                 = "b2b2sqlfileshare"
  storage_account_name = azurerm_storage_account.storage.name
  quota                = 50 # In GBytes
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
    cpu    = "2"
    memory = "4"

    # Open ports of the container
    ports {
      port     = 3000
      protocol = "TCP"
    }

    environment_variables = {
      NEXT_PUBLIC_SUPABASE_URL      = "https://inrqytgeznyswciycjtb.supabase.co"
      NEXT_PUBLIC_SUPABASE_ANON_KEY = var.supabase_anon_key
    }
  }

  image_registry_credential {
    server   = azurerm_container_registry.acr.login_server
    username = var.image_registry_username
    password = var.image_registry_password
  }
}

# Container group for the backend services
resource "azurerm_container_group" "aci-backend" {
  name                = "container_group_backend_b2b"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  ip_address_type     = "Private"
  network_profile_id  = azurerm_network_profile.np-backend.id

  container {
    name   = "sqlserver"
    image  = "mcr.microsoft.com/mssql/server:2022-latest"
    cpu    = "2"
    memory = "4.0"

    ports {
      port     = 1433
      protocol = "TCP"
    }

    environment_variables = {
      ACCEPT_EULA = "Y"
      SA_PASSWORD = var.sql_sa_password
    }

    volume {
      name                 = "mssql-data"
      mount_path           = "/var/opt/mssql"
      read_only            = false
      share_name           = azurerm_storage_share.fileshare.name
      storage_account_name = azurerm_storage_account.storage.name
      storage_account_key  = azurerm_storage_account.storage.primary_access_key
    }
  }

  container {
    name   = "api"
    image  = "${azurerm_container_registry.acr.login_server}/b2b-api:latest"
    cpu    = "0.5"
    memory = "1.5"

    ports {
      port     = 8080
      protocol = "TCP"
    }

    environment_variables = {
      DB_SERVER             = "10.0.2.4"
      DB_NAME               = "BuildingBlocks"
      DB_USER               = "sa"
      DB_PASSWORD           = var.sql_sa_password
      ASPNETCORE_HTTP_PORTS = 8080
      ASPNETCORE_URLS       = "http://0.0.0.0:8080"
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
        },
        "validationCode" = { "type" = "string" }
      }
    }
  })
}

# Add a validation response action
resource "azurerm_logic_app_action_custom" "validation_response" {
  name         = "ValidationResponse"
  logic_app_id = azurerm_logic_app_workflow.webhook_handler.id

  body = jsonencode({
    "type" = "If",
    "expression" = {
      "and" = [
        {
          "not" = {
            "equals" = [
              "@triggerBody()?[0]?['validationCode']",
              null
            ]
          }
        }
      ]
    },
    "actions" = {
      "Response" = {
        "type" = "Response",
        "kind" = "Http",
        "inputs" = {
          "statusCode" = 200,
          "body" = {
            "validationResponse" = "@triggerBody()?[0]?['validationCode']"
          }
        }
      }
    },
    "runAfter" = {}
  })
}

# Add the actual restart action
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
    "runAfter" = {
      "ValidationResponse" = ["Succeeded"]
    },
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

# Give the Logic App permissions to restart the Container resourceGroups
resource "azurerm_role_assignment" "aci_restart_permission_backend" {
  scope                = azurerm_container_group.aci-backend.id
  role_definition_name = "Azure Container Instances Contributor Role"
  principal_id         = azurerm_logic_app_workflow.webhook_handler.identity[0].principal_id
}

resource "azurerm_role_assignment" "aci_restart_permission_frontend" {
  scope                = azurerm_container_group.aci-frontend.id
  role_definition_name = "Azure Container Instances Contributor Role"
  principal_id         = azurerm_logic_app_workflow.webhook_handler.identity[0].principal_id
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
resource "azurerm_eventgrid_system_topic_event_subscription" "logic_app_subscription_frontend" {
  name                = "logic-app-subscription-frontend"
  system_topic        = azurerm_eventgrid_system_topic.acr_events.name
  resource_group_name = azurerm_resource_group.rg.name

  webhook_endpoint {
    #hardcoded signature for validation, this will break when recreating the logic app / workflow..
    url = "${azurerm_logic_app_workflow.webhook_handler.access_endpoint}/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=RhDjb_kv12Z0deiV6SbUVkXPT3pCfTaCIo7mtBhNDwo"

    max_events_per_batch              = 1
    preferred_batch_size_in_kilobytes = 64
  }

  event_delivery_schema = "EventGridSchema"

  included_event_types = ["Microsoft.ContainerRegistry.ImagePushed"]

  # Filter to match your repositories
  advanced_filter {
    string_contains {
      key    = "data.target.repository"
      values = ["b2b-frontend"]
    }
  }

  delivery_property {
    header_name = "X-Event-Type"
    type        = "Static"
    value       = "ACRImagePushed"
  }
}

# Create a second subscription for backend images
resource "azurerm_eventgrid_system_topic_event_subscription" "logic_app_subscription_backend" {
  name                = "logic-app-subscription-backend"
  system_topic        = azurerm_eventgrid_system_topic.acr_events.name
  resource_group_name = azurerm_resource_group.rg.name

  webhook_endpoint {
    #hardcoded signature for validation, this will break when recreating the logic app / workflow..
    url = "${azurerm_logic_app_workflow.webhook_handler.access_endpoint}/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=RhDjb_kv12Z0deiV6SbUVkXPT3pCfTaCIo7mtBhNDwo"

    max_events_per_batch              = 1
    preferred_batch_size_in_kilobytes = 64
  }
  event_delivery_schema = "EventGridSchema"

  included_event_types = ["Microsoft.ContainerRegistry.ImagePushed"]

  # Filter for backend repositories
  advanced_filter {
    string_contains {
      key    = "data.target.repository"
      values = ["b2b-api", "b2b-backend"]
    }
  }

  delivery_property {
    header_name = "X-Event-Type"
    type        = "Static"
    value       = "ACRImagePushed"
  }
}