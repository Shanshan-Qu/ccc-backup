terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    recovery_services {
      # Prevent accidental vault deletion in test; set to false if you need
      # to tear down cleanly without first unregistering items.
      prevent_recovery_services_soft_delete           = false
      vm_backup_stop_protection_and_retain_data_on_destroy = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
