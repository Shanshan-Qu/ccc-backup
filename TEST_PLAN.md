# CCC Azure Backup – Test Plan

> **Version**: 1.1  
> **Environment**: `ME-MngEnvMCAP269331-shanshanqu-6` (sandbox)  
> **Region**: New Zealand North (`newzealandnorth`)  
> **Vault**: `rsv-ccc-backup-nzn-test` in `rg-rsv-backup-nzn`

---

## 1. Overview

This test plan validates the Azure Backup infrastructure deployed via Terraform against the requirements specified in `doc.txt`.  It is divided into:

| Phase | Scope | Status |
|-------|-------|--------|
| **Phase 1 – Infrastructure validation** | Vault, policies, monitoring exist and are correctly configured | ✅ Automated (see §3) |
| **Phase 2 – Azure Files backup**        | File share is registered and a successful backup is taken    | ⚠️ Blocked by sandbox policy (see §6) |
| **Phase 3 – VM backup**                 | Non-prod VM is registered and a successful backup is taken   | ⚠️ Blocked by sandbox quota (see §6) |
| **Phase 4 – SQL backup**                | SQL Server VM registers and log/full/diff backups succeed    | 🔜 Production phase |
| **Phase 5 – Restore tests**             | Recovery from each workload type is verified                 | 🔜 Requires Phase 2/3/4 completion |

---

## 2. Pre-Conditions

| # | Condition | Check |
|---|-----------|-------|
| P1 | Terraform v1.9+ installed | `terraform version` |
| P2 | Azure credentials available | `az account show` or `Connect-AzAccount` |
| P3 | Access to subscription `ee118ff5-df4c-4870-8684-84953408d2ac` | Role: Contributor or Owner |
| P4 | Az PowerShell modules: Az.Accounts, Az.RecoveryServices, Az.Monitor, Az.Network, Az.Storage, Az.OperationalInsights | Auto-installed by the validation script |

---

## 3. Phase 1 – Automated Infrastructure Validation

Run the validation script to confirm every resource is correctly configured:

```powershell
cd "C:\Users\shanshanqu\OneDrive - Microsoft\Customers\CCC\AzureBackup-terraform"
.\scripts\validate-backup-infra.ps1
```

### Test Cases

| ID | Component | Assertion |
|----|-----------|-----------|
| TC01-01 | Vault | `rsv-ccc-backup-nzn-test` exists |
| TC01-02 | Vault | SKU = Standard |
| TC01-03 | Vault | Location = newzealandnorth |
| TC01-04 | Vault | Resource group = rg-rsv-backup-nzn |
| TC01-05 | Vault | Soft-delete enabled |
| TC01-06 | Vault | Diagnostic settings → LAW (allLogs) |
| TC02-01 | Policy | `CCC-Policy` (VM enhanced V2) exists |
| TC02-02 | Policy | `CCC-SQLPolicy` exists |
| TC02-03 | Policy | `CCC-AzFiles-Policy` exists |
| TC02-04 | Policy | VM policy workload type = AzureVM |
| TC02-05 | Policy | VM policy is Enhanced (V2) |
| TC02-06 | Policy | SQL policy workload type = AzureWorkload |
| TC02-07 | Policy | AzFiles policy workload type = AzureFiles |
| TC03-01 | LAW | `law-ccc-backup-nzn-test` exists |
| TC03-02 | LAW | Retention ≥ 30 days |
| TC03-03 | LAW | Location = newzealandnorth |
| TC04-01 | Monitoring | Ops action group exists |
| TC04-02 | Monitoring | Security action group exists |
| TC05-01 | Alerts | Backup health metric alert exists |
| TC05-02 | Alerts | Restore health metric alert exists |
| TC05-03 | Alerts | Resource health activity log alert exists |
| TC05-04 | Alerts | Vault delete activity log alert exists |
| TC05-05 | Alerts | Private endpoint approval alert exists |
| TC05-06 | Alerts | Security PIN alert exists |
| TC06-01 | Alerts | Failed jobs SQR rule exists |
| TC06-02 | Alerts | Storage-per-item SQR rule exists |
| TC06-03 | Alerts | Storage-total SQR rule exists |
| TC07-01 | Networking | Workload VNet (`vnet-ccc-backup-nzn-test`) exists |
| TC07-02 | Networking | Workload NSG (`nsg-workload-nzn-test`) exists |
| TC07-03 | Networking | NSG allows AzureBackup outbound (port 443) |
| TC07-04 | Networking | NSG allows Storage outbound (port 443) |
| TC08-01 | Storage | Storage account `stcccv6hqfn91` exists |
| TC08-02 | Storage | Storage account location = newzealandnorth |
| TC08-03 | Storage | Storage account SKU = Standard_LRS |
| TC08-04 | Storage | Public blob access disabled |
| TC08-05 | Storage | File share `ccc-test-share` exists |

**Pass criteria**: All test cases PASS.

---

## 4. Phase 2 – Azure Files Backup Test (when policy exception granted)

### Pre-conditions
- Storage account `stcccv6hqfn91` has `allowSharedKeyAccess = true`  
  _(Azure Backup requires key auth; policy exception needed — see §6)_
- Uncomment `azurerm_backup_protected_file_share.test` in `workloads.tf` and run `terraform apply`

### Test Steps

```powershell
$vault = Get-AzRecoveryServicesVault -ResourceGroupName "rg-rsv-backup-nzn" -Name "rsv-ccc-backup-nzn-test"
Set-AzRecoveryServicesVaultContext -Vault $vault

# Upload test data
$saCtx = New-AzStorageContext -StorageAccountName "stcccv6hqfn91" -UseConnectedAccount
$tmpFile = New-TemporaryFile
"CCC backup test data – $(Get-Date -Format 'o')" | Out-File $tmpFile
Set-AzStorageFileContent -ShareName "ccc-test-share" -Source $tmpFile -Path "test-data.txt" -Context $saCtx

# Trigger on-demand backup
$container = Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage | Where-Object { $_.FriendlyName -like "*stcccv6hqfn91*" }
$item    = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureFiles
$job     = Backup-AzRecoveryServicesBackupItem -Item $item -ExpiryDateTimeUTC (Get-Date).AddDays(30)
Wait-AzRecoveryServicesBackupJob -Job $job -Timeout 1800

# Verify recovery point
Get-AzRecoveryServicesBackupRecoveryPoint -Item $item | Select-Object -First 5 | Select-Object RecoveryPointId, RecoveryPointType, RecoveryPointTime
```

| Step | Expected Result |
|------|-----------------|
| Upload test file | `test-data.txt` appears in the share |
| Trigger on-demand backup | Job status = `Completed` |
| Verify recovery point | At least 1 recovery point with `RecoveryPointType = FileSystem` |

---

## 5. Phase 3 – VM Backup Test (when NZN VM quota granted)

### Pre-conditions
- VM quota for `Standard_D2s_v5` (or equivalent) available in `NewZealandNorth`  
  _(Currently `NotAvailableForSubscription` — see §6)_
- Uncomment VM resources in `workloads.tf` and run `terraform apply`

### Test Steps

```powershell
$vault = Get-AzRecoveryServicesVault -ResourceGroupName "rg-rsv-backup-nzn" -Name "rsv-ccc-backup-nzn-test"
Set-AzRecoveryServicesVaultContext -Vault $vault

$vmContainer = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM | Where-Object { $_.FriendlyName -like "*vm-ccc-backup*" }
$vmItem      = Get-AzRecoveryServicesBackupItem -Container $vmContainer -WorkloadType AzureVM
$vmJob       = Backup-AzRecoveryServicesBackupItem -Item $vmItem -ExpiryDateTimeUTC (Get-Date).AddDays(7)
Wait-AzRecoveryServicesBackupJob -Job $vmJob -Timeout 3600

Get-AzRecoveryServicesBackupRecoveryPoint -Item $vmItem | Select-Object -First 5 | Select-Object RecoveryPointId, RecoveryPointType, RecoveryPointTime
```

| Step | Expected Result |
|------|-----------------|
| Trigger on-demand VM backup | Job status = `Completed` |
| Verify recovery point | At least 1 recovery point of type `CrashConsistent` or `AppConsistent` |

---

## 6. Sandbox Constraint Log

The following Azure limitations were encountered in the `ME-MngEnvMCAP269331-shanshanqu-6` sandbox and are **not a defect in the Terraform code**:

| # | Constraint | Impact | Resolution |
|---|-----------|--------|------------|
| C1 | **VM quota**: all VM SKUs return `NotAvailableForSubscription` in NZN for this sandbox | Cannot create test VMs → cannot test VM backup end-to-end | Request VM quota: Azure Portal → Subscriptions → Usage + Quotas → Request Increase |
| C2 | **Storage key auth policy**: subscription policy enforces `allowSharedKeyAccess=false` | Azure Files backup requires key auth → cannot register file share with vault | Request policy exception for `stccc*` storage accounts, or wait for Azure Backup MSI-based file share support |

The Terraform code is correct and complete. The workload resources (VNet, subnet, NSG, storage account, file share) are fully deployed and will work once these constraints are resolved.

---

## 7. Portal Verification Checklist

After automated validation, spot-check in the Azure Portal:

- [ ] **Vault → Backup items**: no unexpected items or error states
- [ ] **Vault → Backup jobs**: no stuck or failed jobs
- [ ] **Vault → Backup policies**: CCC-Policy, CCC-SQLPolicy, CCC-AzFiles-Policy visible with correct schedules
- [ ] **Vault → Security settings**: Soft-delete enabled, immutability configured
- [ ] **LAW → Logs**: `AddonAzureBackupJobs` table exists and is receiving data
- [ ] **Monitor → Alerts**: All alert rules listed and enabled
- [ ] **Monitor → Action groups**: Email addresses correct in both action groups

---

## 8. Restore Test Plan (production only)

Once Phase 2 or Phase 3 backups succeed, perform at minimum one restore:

### Azure Files Restore
1. Azure Portal → `rsv-ccc-backup-nzn-test` → Backup items → Azure Storage → `ccc-test-share`
2. Click **Restore Files** → select the latest recovery point
3. Restore `test-data.txt` to an alternate location
4. **Expected**: file content matches original upload

### VM Restore (File-Level)
1. Azure Portal → `rsv-ccc-backup-nzn-test` → Backup items → Azure Virtual Machine → `vm-ccc-backup-nzn-test-01`
2. Click **File Recovery** → Mount the recovery point as a network share
3. Browse `/opt/ccc-testdata/sample.txt`
4. **Expected**: file content contains `CCC Azure Backup Test Workload`

---

## 9. Pass/Fail Criteria

| Criterion | Required for Pass |
|-----------|------------------|
| Infrastructure validation (Phase 1) | All TC01–TC08 PASS |
| No Terraform drift | `terraform plan` exits with code 0 |
| Azure Files backup (Phase 2) | Job status = Completed; ≥1 recovery point (when sandbox policy allows) |
| VM backup (Phase 3) | Job status = Completed; ≥1 recovery point (when NZN quota allows) |
| Restore test | File content matches original (when backup phases complete) |
