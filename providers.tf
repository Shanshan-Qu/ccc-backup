terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  subscription_id      = var.subscription_id
  storage_use_azuread  = true  # Subscription policy disables shared-key access; use Entra ID for storage data plane

  features {
    recovery_service {
      # Allow vault deletion during teardown without unregistering items first.
      vm_backup_stop_protection_and_retain_data_on_destroy = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
