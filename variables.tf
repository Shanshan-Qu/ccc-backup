variable "subscription_id" {
  description = "Azure Subscription ID in which to deploy all resources."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "newzealandnorth"
}

variable "environment" {
  description = "Short environment label (e.g. test, dev, prod)."
  type        = string
  default     = "test"
}

variable "workload" {
  description = "Workload identifier used in resource names."
  type        = string
  default     = "backup"
}

variable "private_endpoint_subnet_id" {
  description = <<-EOT
    Resource ID of the subnet in the spoke VNet to attach the Recovery Services
    vault private endpoint.  Leave empty to skip private-endpoint creation
    (useful for a quick smoke test before networking is set up).
  EOT
  type        = string
  default     = ""
}

variable "private_dns_zone_ids" {
  description = <<-EOT
    List of Private DNS Zone resource IDs to associate with the vault private
    endpoint.  Typically contains the zone for
    privatelink.{location}.backup.windowsazure.com and (if needed)
    privatelink.blob.core.windows.net.
  EOT
  type        = list(string)
  default     = []
}

variable "log_analytics_retention_days" {
  description = "Retention period (days) for the Log Analytics workspace."
  type        = number
  default     = 90

  validation {
    condition     = var.log_analytics_retention_days >= 30 && var.log_analytics_retention_days <= 730
    error_message = "Retention must be between 30 and 730 days."
  }
}

variable "enable_immutability" {
  description = "Set to true to enable Unlocked vault immutability (optional for non-prod)."
  type        = bool
  default     = false
}

variable "backup_contributor_principal_ids" {
  description = "List of Entra ID object IDs to assign the Backup Contributor role on the vault."
  type        = list(string)
  default     = []
}

variable "backup_operator_principal_ids" {
  description = "List of Entra ID object IDs to assign the Backup Operator role on the vault."
  type        = list(string)
  default     = []
}

variable "backup_reader_principal_ids" {
  description = "List of Entra ID object IDs to assign the Backup Reader role on the vault."
  type        = list(string)
  default     = []
}

variable "rsv_contributor_principal_ids" {
  description = "List of Entra ID object IDs to assign the Recovery Services Contributor role on the vault."
  type        = list(string)
  default     = []
}

variable "alert_email_receivers" {
  description = "List of e-mail addresses for the backup operations action group."
  type        = list(string)
  default     = []
}

variable "alert_email_receivers_security" {
  description = "List of e-mail addresses for the security / platform-ops action group (admin events)."
  type        = list(string)
  default     = []
}

variable "restore_target_subscription_id" {
  description = <<-EOT
    Subscription ID to use as the restore destination for cross-subscription
    restore tests (Phase 5).  Defaults to the same subscription as the vault;
    override with a second subscription ID to exercise true cross-subscription
    restore.  Must be in the same Azure AD tenant.
  EOT
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags to merge with the default tags."
  type        = map(string)
  default     = {}
}
