# CCC Azure Backup – Test Plan

> **Version**: 3.1  
> **Environment**: `ShanshanQu-NonProd` (subscription `634c603a-fa54-431f-8fdd-2279020b1cb9`)  
> **Region**: New Zealand North (`newzealandnorth`)  
> **Vault**: `rsv-ccc-backup-nzn-test` in `rg-rsv-backup-nzn`  
> **Alert notifications**: `shanshanqu@microsoft.com`

**What changed in v3.1**: Added Phase 5 – Cross-Subscription Restore, covering VM disk restore, Azure Files restore, and SQL restore into an alternative subscription. Added `restore_target_subscription_id` variable.

**What changed in v3.0**: VM-quota and Azure Files shared-key constraints are resolved on this subscription. Azure Files backup protection is now fully managed by Terraform (no Portal step). A test-data seeding phase and a full SQL workload backup/restore phase have been added.

---

## Common Session Variables

Set these once at the top of every PowerShell session before running any phase below.

```powershell
$Sub       = "634c603a-fa54-431f-8fdd-2279020b1cb9"
$RG        = "rg-rsv-backup-nzn"
$Vault     = "rsv-ccc-backup-nzn-test"
$VMName    = "vm-ccc-backup-nzn-test-01"
$SQLVMName = "vm-ccc-sql-nzn-test-01"
$Share     = "ccc-test-share"

# Resolve the storage account name from Terraform output
$SAName = terraform output -raw workload_storage_account_name

az account set --subscription $Sub

# Set vault context (used by all Az.RecoveryServices cmdlets)
$v = Get-AzRecoveryServicesVault -ResourceGroupName $RG -Name $Vault
Set-AzRecoveryServicesVaultContext -Vault $v
```

---

## 1. Pre-Conditions

| # | Condition | Command |
|---|-----------|---------|
| P1 | Logged in to correct subscription | `az account show` → `id` = `634c603a-fa54-431f-8fdd-2279020b1cb9` |
| P2 | Terraform apply complete, no drift | `terraform plan` exits with "No changes" |
| P3 | Linux VM running | `az vm get-instance-view -g $RG -n $VMName --query "instanceView.statuses[1].displayStatus" -o tsv` → `VM running` |
| P4 | SQL VM running | `az vm get-instance-view -g $RG -n $SQLVMName --query "instanceView.statuses[1].displayStatus" -o tsv` → `VM running` |
| P5 | File share exists | `az storage share exists --account-name $SAName --name $Share --auth-mode login -o tsv` → `True` |

---

## 2. Deploy / Re-deploy

```powershell
cd "C:\Users\shanshanqu\OneDrive - Microsoft\Customers\CCC\AzureBackup-terraform"
az account set --subscription $Sub
& "C:\Users\shanshanqu\bin\terraform\terraform.exe" apply -auto-approve
```

---

## 2a. Automated Smoke Test – `run-backup-test.ps1`

The script `scripts/run-backup-test.ps1` automates all seeding, backup triggering, job waiting, and recovery point verification steps in one run. Use it as a quick end-to-end smoke test after `terraform apply`.

### Prerequisites

```powershell
# Ensure Az PowerShell modules are available (script will install them if missing)
# Ensure az CLI is authenticated
az account show

# Ensure terraform outputs are available (script reads them automatically)
terraform output workload_storage_account_name
terraform output workload_vm_name
terraform output sql_vm_name
```

### Run with defaults (all values auto-resolved from terraform output)

```powershell
cd "C:\Users\shanshanqu\OneDrive - Microsoft\Customers\CCC\AzureBackup-terraform"
.\scripts\run-backup-test.ps1
```

### Run with explicit resource names (no terraform state required)

```powershell
.\scripts\run-backup-test.ps1 `
    -SubscriptionId     "634c603a-fa54-431f-8fdd-2279020b1cb9" `
    -ResourceGroup      "rg-rsv-backup-nzn" `
    -VaultName          "rsv-ccc-backup-nzn-test" `
    -StorageAccountName "stccc<suffix>" `
    -FileShareName      "ccc-test-share" `
    -VmName             "vm-ccc-backup-nzn-test-01" `
    -SqlVmName          "vm-ccc-sql-nzn-test-01"
```

### What the script does (test cases)

| TC | Step | What it covers |
|----|------|---------------|
| TC001 | Upload test files to Azure File Share | Phase 2 seeding |
| TC002-SQL-Seed | Create `CCCTestDB` + seed 50 rows on SQL VM via run-command | Phase 3 seeding |
| TC002 | Trigger on-demand file share backup | Phase 2 backup |
| TC003 | Trigger on-demand Linux VM backup | Phase 1 backup |
| TC004 | Wait for file share backup job | Phase 2 verification |
| TC005 | Wait for VM backup job | Phase 1 verification |
| TC006-SQL | Register SQL container, enable DB protection, trigger full backup | Phase 3 backup |
| TC007-SQL | Wait for SQL backup job | Phase 3 verification |
| TC006 | Verify file share has ≥1 recovery point | Phase 2 recovery point |
| TC007 | Verify VM has ≥1 recovery point | Phase 1 recovery point |
| TC008 | Verify `CCCTestDB` has ≥1 recovery point | Phase 3 recovery point |

### Expected output (all passing)

```
>>> TC001 – Uploading test file to 'ccc-test-share' in 'stccc...'
[PASS] TC001 – Test file uploaded to ccc-test-share/backup-test/
>>> TC002-SQL-Seed – Creating CCCTestDB and seeding 50 rows on SQL VM '...'
[PASS] TC002-SQL-Seed – CCCTestDB created and seeded. Output: TotalRows 50
...
============================================================
  CCC Azure Backup Test Results
============================================================
 Test Case       Status  Detail
 -----------     ------  ------
 TC001           PASS    Test file uploaded ...
 TC002-SQL-Seed  PASS    CCCTestDB created and seeded ...
 ...
  Passed : 10 / 10
  ALL TESTS PASSED
```

> **Tip**: Phases 4 (Alerts) and 5 (Cross-Subscription Restore) are manual steps — run them separately following Sections 7 and 9 of this plan.

---

## 3. Phase 0 – Test Data Seeding

Seed all three backup targets before running any backup jobs.

### 3.1 Verify Linux VM Test Files

The cloud-init script creates `/opt/ccc-testdata/sample.txt` and `workload.log`. Confirm they are present:

```powershell
az vm run-command invoke `
  --resource-group $RG --name $VMName `
  --command-id RunShellScript `
  --scripts "ls -lh /opt/ccc-testdata/ && cat /opt/ccc-testdata/sample.txt" `
  --query "value[0].message" -o tsv
```

**Expected**: Directory listing shows `sample.txt` and `workload.log`; content begins with `=== CCC Azure Backup Test Workload ===`

### 3.2 Add Extra Test Files on Linux VM

Creates a subfolder with additional files to exercise file-level restore depth:

```powershell
az vm run-command invoke `
  --resource-group $RG --name $VMName `
  --command-id RunShellScript `
  --scripts 'mkdir -p /opt/ccc-testdata/subdir
echo "Extra seed file – $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /opt/ccc-testdata/extra1.txt
cp /opt/ccc-testdata/sample.txt /opt/ccc-testdata/subdir/sample-copy.txt
printf "Line1\nLine2\nLine3\n" > /opt/ccc-testdata/subdir/nested.txt
ls -lhR /opt/ccc-testdata/' `
  --query "value[0].message" -o tsv
```

**Expected**: `extra1.txt` and `subdir/` with two files listed.

### 3.3 Upload Test Files to Azure File Share

```powershell
# Auth via shared key (enabled on this subscription)
$key = (Get-AzStorageAccountKey -ResourceGroupName $RG -Name $SAName)[0].Value
$ctx = New-AzStorageContext -StorageAccountName $SAName -StorageAccountKey $key

# Create testdata directory in the share
New-AzStorageDirectory -ShareName $Share -Path "testdata" -Context $ctx -ErrorAction SilentlyContinue

# Seed file 1 – text content with timestamp
$tmp1 = New-TemporaryFile
"CCC Azure Backup – File Share Seed File`nTimestamp: $(Get-Date -Format 'o')`nWorkload: AzureFiles" |
    Out-File $tmp1 -Encoding utf8
Set-AzStorageFileContent -ShareName $Share -Source $tmp1 -Path "testdata/seed-file.txt" -Context $ctx -Force

# Seed file 2 – CSV with 200 records
1..200 | ForEach-Object { "Record $_,$(New-Guid),$(Get-Date -Format 'o')" } |
    Out-File "$env:TEMP\records.csv" -Encoding utf8
Set-AzStorageFileContent -ShareName $Share -Source "$env:TEMP\records.csv" -Path "testdata/records.csv" -Context $ctx -Force

# Verify
Get-AzStorageFile -ShareName $Share -Path "testdata" -Context $ctx | Get-AzStorageFile |
    Select-Object Name, Length
```

**Expected**: `seed-file.txt` and `records.csv` listed under `testdata/`

### 3.4 Create SQL Test Database and Seed Data

Creates `CCCTestDB` on the SQL VM with 50 test rows. Commands run via the VM Run-Command extension — no Bastion or VPN required.

```powershell
# Step 1 – Create the database
az vm run-command invoke `
  --resource-group $RG --name $SQLVMName `
  --command-id RunPowerShellScript `
  --scripts 'sqlcmd -S localhost -E -Q "IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = ''CCCTestDB'') CREATE DATABASE CCCTestDB"'

# Step 2 – Create table
az vm run-command invoke `
  --resource-group $RG --name $SQLVMName `
  --command-id RunPowerShellScript `
  --scripts 'sqlcmd -S localhost -E -d CCCTestDB -Q "IF OBJECT_ID(''dbo.BackupTestRecords'') IS NULL CREATE TABLE dbo.BackupTestRecords (Id INT IDENTITY PRIMARY KEY, RecordName NVARCHAR(100) NOT NULL, SeededAt DATETIME2 DEFAULT SYSUTCDATETIME(), Payload NVARCHAR(MAX))"'

# Step 3 – Seed 50 rows and verify
az vm run-command invoke `
  --resource-group $RG --name $SQLVMName `
  --command-id RunPowerShellScript `
  --scripts 'sqlcmd -S localhost -E -d CCCTestDB -Q "DECLARE @i INT=1; WHILE @i<=50 BEGIN INSERT dbo.BackupTestRecords(RecordName,Payload) VALUES(CONCAT(''CCC-Record-'',FORMAT(@i,''000'')),CONCAT(''{\"index\":'',@i,''}''));SET @i=@i+1 END; SELECT COUNT(*) AS TotalRows FROM dbo.BackupTestRecords; SELECT TOP 3 Id,RecordName,SeededAt FROM dbo.BackupTestRecords"' `
  --query "value[0].message" -o tsv
```

**Expected**: `TotalRows = 50`, top 3 rows show `CCC-Record-001`, `CCC-Record-002`, `CCC-Record-003`

---

## 4. Phase 1 – VM Backup & Restore

### 4.1 Trigger On-Demand VM Backup

```powershell
$c    = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -FriendlyName $VMName -VaultId $v.ID
$item = Get-AzRecoveryServicesBackupItem -Container $c -WorkloadType AzureVM -VaultId $v.ID
$job  = Backup-AzRecoveryServicesBackupItem -Item $item -ExpiryDateTimeUTC (Get-Date).AddDays(7) -VaultId $v.ID
Wait-AzRecoveryServicesBackupJob -Job $job -Timeout 3600 -VaultId $v.ID
$job | Select-Object Operation, Status, StartTime, EndTime
```

**Expected**: `Status = Completed`

### 4.2 Verify Recovery Point

```powershell
$rps = Get-AzRecoveryServicesBackupRecoveryPoint -Item $item -VaultId $v.ID
$rps | Sort-Object RecoveryPointTime -Descending |
    Select-Object -First 3 RecoveryPointId, RecoveryPointType, RecoveryPointTime
```

**Expected**: At least 1 recovery point of type `CrashConsistent` or `AppConsistent`

### 4.3 File-Level Restore from VM Backup

```powershell
$rp   = $rps | Sort-Object RecoveryPointTime -Descending | Select-Object -First 1
$disk = Get-AzRecoveryServicesBackupRPMountScript -RecoveryPoint $rp -VaultId $v.ID
# Run the generated script locally to mount the recovery volume
# Browse to /opt/ccc-testdata/ and confirm sample.txt, extra1.txt, and subdir/ are present
```

**Expected**: `/opt/ccc-testdata/sample.txt` contains `=== CCC Azure Backup Test Workload ===`; `extra1.txt` and `subdir/nested.txt` from Phase 0.2 are also visible.

---

## 5. Phase 2 – Azure Files Backup & Restore

File share backup protection is now configured by Terraform (`azurerm_backup_protected_file_share`). No Portal step is required.

### 5.1 Trigger On-Demand File Share Backup

```powershell
$sc   = Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -VaultId $v.ID |
            Where-Object { $_.FriendlyName -like "*$SAName*" }
$item = Get-AzRecoveryServicesBackupItem -Container $sc -WorkloadType AzureFiles -VaultId $v.ID |
            Where-Object { $_.FriendlyName -eq $Share }
$job  = Backup-AzRecoveryServicesBackupItem -Item $item -ExpiryDateTimeUTC (Get-Date).AddDays(30) -VaultId $v.ID
Wait-AzRecoveryServicesBackupJob -Job $job -Timeout 1800 -VaultId $v.ID
$job | Select-Object Operation, Status, StartTime, EndTime
```

**Expected**: `Status = Completed`

### 5.2 Restore a Single File to an Alternate Folder

```powershell
$rps = Get-AzRecoveryServicesBackupRecoveryPoint -Item $item -VaultId $v.ID
$rp  = $rps | Sort-Object RecoveryPointTime -Descending | Select-Object -First 1

Restore-AzRecoveryServicesBackupItem `
  -RecoveryPoint               $rp `
  -StorageAccountName          $SAName `
  -StorageAccountResourceGroupName $RG `
  -ResolveConflict             Overwrite `
  -SourceFilePath              "testdata/seed-file.txt" `
  -SourceFileType              File `
  -TargetStorageAccountName    $SAName `
  -TargetFileShareName         $Share `
  -TargetFolder                "restored" `
  -VaultId                     $v.ID
```

**Expected**: `testdata/seed-file.txt` is restored to `restored/seed-file.txt` in the same share with matching content.

Verify:

```powershell
$key = (Get-AzStorageAccountKey -ResourceGroupName $RG -Name $SAName)[0].Value
$ctx = New-AzStorageContext -StorageAccountName $SAName -StorageAccountKey $key
Get-AzStorageFile -ShareName $Share -Path "restored" -Context $ctx | Get-AzStorageFile |
    Select-Object Name, Length
```

---

## 6. Phase 3 – SQL Database Backup & Restore

The `azurerm_mssql_virtual_machine` resource already registers the SQL IaaS extension. The steps below register the VM as a workload container, discover the SQL databases, enable protection, and run an on-demand backup.

### 6.1 Register SQL Workload Container

```powershell
$sqlVMId = az vm show -g $RG -n $SQLVMName --query id -o tsv

# Register the SQL VM as an AzureVMAppContainer in the vault
Register-AzRecoveryServicesBackupContainer `
  -ResourceId            $sqlVMId `
  -BackupManagementType  AzureWorkload `
  -WorkloadType          SQLDataBase `
  -VaultId               $v.ID `
  -Force

# Confirm registration
$sc = Get-AzRecoveryServicesBackupContainer `
        -ContainerType AzureVMAppContainer `
        -VaultId       $v.ID |
        Where-Object { $_.FriendlyName -like "*$SQLVMName*" }
$sc | Select-Object FriendlyName, Status
```

**Expected**: Container listed with `Status = Registered`

### 6.2 Discover SQL Databases

```powershell
# Trigger discovery — detects all SQL instances and DBs on the registered VM
Initialize-AzRecoveryServicesBackupProtectableItem `
  -WorkloadType SQLDataBase -VaultId $v.ID -Container $sc

$protectableItems = Get-AzRecoveryServicesBackupProtectableItem `
  -WorkloadType SQLDataBase -ItemType SQLDataBase -VaultId $v.ID |
  Where-Object { $_.ParentContainerFriendlyName -like "*$SQLVMName*" }

$protectableItems | Select-Object FriendlyName, Name, ParentContainerFriendlyName
```

**Expected**: `CCCTestDB` appears in the list (alongside system DBs like `master`, `model`, `msdb`).

### 6.3 Enable SQL DB Protection

```powershell
$dbItem  = $protectableItems | Where-Object { $_.FriendlyName -eq "CCCTestDB" }
$sqlPolicy = Get-AzRecoveryServicesBackupProtectionPolicy -Name "CCC-SQL-Workload-Policy" -VaultId $v.ID

Enable-AzRecoveryServicesBackupProtection `
  -ProtectableItem $dbItem `
  -Policy          $sqlPolicy `
  -VaultId         $v.ID
```

**Expected**: Protection is enabled; the DB appears in backup items with `ProtectionState = IRPending` (initial backup pending).

### 6.4 Trigger On-Demand SQL Full Backup

```powershell
$sqlItem = Get-AzRecoveryServicesBackupItem `
  -WorkloadType         SQLDataBase `
  -BackupManagementType AzureWorkload `
  -VaultId              $v.ID |
  Where-Object { $_.FriendlyName -eq "CCCTestDB" }

$job = Backup-AzRecoveryServicesBackupItem `
  -Item                $sqlItem `
  -BackupType          Full `
  -ExpiryDateTimeUTC   (Get-Date).AddDays(7) `
  -VaultId             $v.ID

Wait-AzRecoveryServicesBackupJob -Job $job -Timeout 3600 -VaultId $v.ID
$job | Select-Object Operation, Status, StartTime, EndTime
```

**Expected**: `Status = Completed`

### 6.5 Verify SQL Recovery Point

```powershell
$sqlRPs = Get-AzRecoveryServicesBackupRecoveryPoint -Item $sqlItem -VaultId $v.ID
$sqlRPs | Sort-Object RecoveryPointTime -Descending |
    Select-Object -First 3 RecoveryPointId, RecoveryPointType, RecoveryPointTime
```

**Expected**: At least 1 recovery point of type `Full`

### 6.6 Restore SQL Database to a New Database

```powershell
$rp = $sqlRPs | Sort-Object RecoveryPointTime -Descending | Select-Object -First 1

# Build a restore config targeting the same SQL instance, alternate DB name
$restoreConfig = Get-AzRecoveryServicesBackupWorkloadRecoveryConfig `
  -RecoveryPoint          $rp `
  -TargetItem             $sqlItem `
  -AlternateWorkloadRestore `
  -VaultId                $v.ID

$restoreConfig.RestoredDBName     = "CCCTestDB_Restored"
$restoreConfig.OverwriteWLIfpresent = $true

$restoreJob = Restore-AzRecoveryServicesBackupItem `
  -WLRecoveryConfig $restoreConfig `
  -VaultId          $v.ID

Wait-AzRecoveryServicesBackupJob -Job $restoreJob -Timeout 3600 -VaultId $v.ID
$restoreJob | Select-Object Operation, Status, StartTime, EndTime
```

**Expected**: `Status = Completed`

### 6.7 Verify Restored Database

```powershell
az vm run-command invoke `
  --resource-group $RG --name $SQLVMName `
  --command-id RunPowerShellScript `
  --scripts 'sqlcmd -S localhost -E -d CCCTestDB_Restored -Q "SELECT COUNT(*) AS RestoredRows FROM dbo.BackupTestRecords; SELECT TOP 3 Id,RecordName,SeededAt FROM dbo.BackupTestRecords"' `
  --query "value[0].message" -o tsv
```

**Expected**: `RestoredRows = 50`, top 3 rows match the original seed data.

---

## 7. Phase 4 – Alert Trigger Tests

All alerts send email to `shanshanqu@microsoft.com`.

### 7.1 Failed Backup Job Alert (Sev1)

Deallocate the VM then immediately trigger an on-demand backup — it will fail with `UserErrorVmNotInDesirableState`:

```powershell
az vm deallocate --resource-group $RG --name $VMName

$c    = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -FriendlyName $VMName -VaultId $v.ID
$item = Get-AzRecoveryServicesBackupItem -Container $c -WorkloadType AzureVM -VaultId $v.ID
Backup-AzRecoveryServicesBackupItem -Item $item -ExpiryDateTimeUTC (Get-Date).AddDays(1) -VaultId $v.ID

# Restart VM after confirming the alert email is received
az vm start --resource-group $RG --name $VMName
```

**Expected email**: Subject contains `Fired: alert-rsv-ccc-backup-nzn-test-failed-jobs` within ~30 minutes.

### 7.2 Backup Health Event Alert (Sev1)

Stop the VM, trigger backup to generate a health event, then restart:

```powershell
az vm stop --resource-group $RG --name $VMName

$c    = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -FriendlyName $VMName -VaultId $v.ID
$item = Get-AzRecoveryServicesBackupItem -Container $c -WorkloadType AzureVM -VaultId $v.ID
Backup-AzRecoveryServicesBackupItem -Item $item -ExpiryDateTimeUTC (Get-Date).AddDays(1) -VaultId $v.ID

az vm start --resource-group $RG --name $VMName
```

**Expected email**: Alert for backup health degradation within ~15 minutes.

### 7.3 Vault Delete Alert (Sev2 — Admin/Security)

Initiate (but not complete) a vault delete — the activity log alert fires on the attempt, not the outcome:

```powershell
# This will fail because the vault is not empty — that is intentional.
az backup vault delete --resource-group $RG --name $Vault --yes 2>&1
```

**Expected email**: Subject contains `alert-rsv-ccc-backup-nzn-test-admin-delete` within ~5 minutes.

### 7.4 Security PIN Retrieval Alert (Sev2 — Admin/Security)

```powershell
az rest --method POST `
  --uri "https://management.azure.com/subscriptions/$Sub/resourceGroups/$RG/providers/Microsoft.RecoveryServices/vaults/$Vault/backupSecurityPin/action?api-version=2023-04-01"
```

**Expected email**: Subject contains `alert-rsv-ccc-backup-nzn-test-admin-security-pin` within ~5 minutes.

---

## 8. Alert Expected Email Summary

| Alert | Trigger | Expected within |
|-------|---------|----------------|
| Failed backup jobs | VM deallocated, backup job fails | 30 min |
| Backup health event | VM stopped during backup cycle | 15 min |
| Vault delete attempt | `az backup vault delete` | 5 min |
| Security PIN retrieval | `backupSecurityPin/action` API call | 5 min |
| Resource health change | Azure platform degrades vault | Platform-driven |

| Storage per-item threshold | Item exceeds 500 GB | Daily evaluation |
| Storage total threshold | Vault exceeds 1 TB | Daily evaluation |

---

## 9. Phase 5 – Cross-Subscription Restore

> **Requirement**: The vault must reside in the same subscription as its backup targets, but restore operations must be executable into an alternative subscription. This enables production backups to be seeded down into non-production environments.

### Background

Cross-subscription restore (CSR) is enabled by **default** on new Azure Recovery Services vaults (the `cross_subscription_restore_enabled` property defaults to `true` in the azurerm provider). This plan verifies CSR is active and exercises it for VM, Azure Files, and SQL workloads.

A second subscription is needed to test true cross-subscription restore. In the absence of one, substitute with an alternate resource group in the **same** subscription — this exercises the same restore code path and API (`--target-subscription-id`) with the relaxed constraint of a single-subscription lab.

### 9.0 Session Variables for CSR Phase

```powershell
# Target subscription — set to a second sub ID to test true CSR;
# leave equal to $Sub to use the same subscription (alternate RG instead)
$TargetSub = "634c603a-fa54-431f-8fdd-2279020b1cb9"   # replace if you have a second sub
$TargetRG  = "rg-ccc-restore-target"                   # created below if it does not exist

az account set --subscription $Sub   # ensure vault context stays on source sub
```

### 9.1 Verify Cross-Subscription Restore Is Enabled

```powershell
# Check vault CSR state via REST API
$vaultId = az backup vault show -g $RG -n $Vault --query id -o tsv
az rest --method GET `
  --uri "https://management.azure.com${vaultId}?api-version=2024-04-01" `
  --query "properties.restoreSettings.crossSubscriptionRestoreSettings.crossSubscriptionRestoreState" `
  -o tsv
```

**Expected**: `Enabled`

If the result is `Disabled` or `PermanentlyDisabled`, re-enable via:

```powershell
az rest --method PATCH `
  --uri "https://management.azure.com${vaultId}?api-version=2024-04-01" `
  --body '{"properties":{"restoreSettings":{"crossSubscriptionRestoreSettings":{"crossSubscriptionRestoreState":"Enabled"}}}}' `
  --headers "Content-Type=application/json"
```

### 9.2 Prepare Target Subscription / Resource Group

```powershell
# Switch context to the TARGET subscription to create the restore landing zone
az account set --subscription $TargetSub
az group create --name $TargetRG --location newzealandnorth

# For Files restore: create a target storage account
$TargetSA = "stcccrestore$(Get-Random -Maximum 9999)"
az storage account create `
  --name $TargetSA --resource-group $TargetRG `
  --location newzealandnorth --sku Standard_LRS --kind StorageV2

# Create the target file share
az storage share-rm create --name "restored-cross-sub" `
  --storage-account $TargetSA --resource-group $TargetRG --quota 5

# Switch back to the SOURCE subscription for all backup cmdlets
az account set --subscription $Sub
Set-AzContext -SubscriptionId $Sub | Out-Null
$v = Get-AzRecoveryServicesVault -ResourceGroupName $RG -Name $Vault
Set-AzRecoveryServicesVaultContext -Vault $v
```

### 9.3 Cross-Subscription VM Restore (Restore Disks)

Restore the latest VM recovery point as managed disks into the target subscription. This is the pattern used to seed a non-production VM from a production backup.

```powershell
# Get latest VM recovery point
$c   = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -FriendlyName $VMName -VaultId $v.ID
$item = Get-AzRecoveryServicesBackupItem -Container $c -WorkloadType AzureVM -VaultId $v.ID
$rp  = Get-AzRecoveryServicesBackupRecoveryPoint -Item $item -VaultId $v.ID |
           Sort-Object RecoveryPointTime -Descending | Select-Object -First 1

# Build restore config targeting the alternate subscription's resource group
$restoreConfig = Get-AzRecoveryServicesBackupWorkloadRecoveryConfig `
  -RecoveryPoint $rp -VaultId $v.ID

# Use Az CLI for the actual restore — it supports --target-subscription-id natively
$rpName = $rp.RecoveryPointId.Split('/')[-1]
$containerName = $c.Name

az backup restore restore-disks `
  --resource-group $RG `
  --vault-name     $Vault `
  --container-name $containerName `
  --item-name      $VMName `
  --rp-name        $rpName `
  --storage-account $TargetSA `
  --target-resource-group $TargetRG `
  --target-subscription-id $TargetSub `
  --restore-mode  AlternateLocation
```

**Expected**: Restore job completes with `Status = Completed`; managed disks appear in `$TargetRG` of `$TargetSub`.

Verify:

```powershell
az disk list --resource-group $TargetRG --subscription $TargetSub `
  --query "[].{name:name, sizeGb:diskSizeGb, state:diskState}" -o table
```

### 9.4 Cross-Subscription Azure Files Restore

```powershell
$sc   = Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -VaultId $v.ID |
            Where-Object { $_.FriendlyName -like "*$SAName*" }
$item = Get-AzRecoveryServicesBackupItem -Container $sc -WorkloadType AzureFiles -VaultId $v.ID |
            Where-Object { $_.FriendlyName -eq $Share }
$rp   = Get-AzRecoveryServicesBackupRecoveryPoint -Item $item -VaultId $v.ID |
            Sort-Object RecoveryPointTime -Descending | Select-Object -First 1

Restore-AzRecoveryServicesBackupItem `
  -RecoveryPoint                   $rp `
  -TargetStorageAccountName        $TargetSA `
  -TargetFileShareName             "restored-cross-sub" `
  -TargetFolder                    "from-backup" `
  -ResolveConflict                 Overwrite `
  -SourceFilePath                  "testdata/seed-file.txt" `
  -SourceFileType                  File `
  -StorageAccountName              $SAName `
  -StorageAccountResourceGroupName $RG `
  -VaultId                         $v.ID
```

**Expected**: Job completes; `restored-cross-sub/from-backup/seed-file.txt` exists in `$TargetSA` within `$TargetSub`.

Verify:

```powershell
az storage file list `
  --account-name $TargetSA --share-name "restored-cross-sub" `
  --path "from-backup" --subscription $TargetSub -o table
```

### 9.5 Cross-Subscription SQL Restore

```powershell
# Get latest SQL recovery point for CCCTestDB
$sqlItem = Get-AzRecoveryServicesBackupItem `
  -WorkloadType SQLDataBase -BackupManagementType AzureWorkload -VaultId $v.ID |
  Where-Object { $_.FriendlyName -eq "CCCTestDB" }
$sqlRPs = Get-AzRecoveryServicesBackupRecoveryPoint -Item $sqlItem -VaultId $v.ID
$rp     = $sqlRPs | Sort-Object RecoveryPointTime -Descending | Select-Object -First 1

# Build restore config — alternate location restore into a SQL instance on the TARGET sub
# Requires a SQL VM registered in the target subscription's vault (or same-sub alternate instance)
$targetSQLVM = az vm show -g $TargetRG -n "<target-sql-vm-name>" --subscription $TargetSub --query id -o tsv

$restoreCfg = Get-AzRecoveryServicesBackupWorkloadRecoveryConfig `
  -RecoveryPoint          $rp `
  -TargetItem             $sqlItem `
  -AlternateWorkloadRestore `
  -VaultId                $v.ID

$restoreCfg.RestoredDBName            = "CCCTestDB_CrossSub"
$restoreCfg.OverwriteWLIfpresent      = $true
$restoreCfg.TargetVirtualMachineId    = $targetSQLVM

$job = Restore-AzRecoveryServicesBackupItem -WLRecoveryConfig $restoreCfg -VaultId $v.ID
Wait-AzRecoveryServicesBackupJob -Job $job -Timeout 3600 -VaultId $v.ID
$job | Select-Object Operation, Status, StartTime, EndTime
```

**Expected**: `Status = Completed`; `CCCTestDB_CrossSub` appears on the target SQL instance.

> **Note**: SQL cross-subscription restore requires the target SQL VM to be registered as an `AzureVMAppContainer` in a vault within `$TargetSub`. In a single-subscription lab, point `$targetSQLVM` at a second SQL VM in the same subscription.

### 9.6 Clean Up Restore Target

```powershell
az account set --subscription $TargetSub
az group delete --name $TargetRG --yes --no-wait
az account set --subscription $Sub
```

---

## 10. Consolidated Pass / Fail Criteria

| Phase | Test | Pass Condition |
|-------|------|---------------|
| VM backup | On-demand backup | Job `Status = Completed`, ≥1 recovery point |
| VM backup | File-level restore | `/opt/ccc-testdata/sample.txt` accessible with correct content |
| Azure Files | On-demand backup | Job `Status = Completed`, ≥1 recovery point |
| Azure Files | File restore | `restored/seed-file.txt` present with matching content |
| SQL | On-demand full backup | Job `Status = Completed`, ≥1 `Full` recovery point |
| SQL | Database restore | `CCCTestDB_Restored` exists with 50 rows |
| CSR | Vault CSR enabled | REST query returns `Enabled` |
| CSR | VM cross-sub restore | Managed disks present in `$TargetRG` / `$TargetSub` |
| CSR | Files cross-sub restore | `seed-file.txt` present in target share with matching content |
| CSR | SQL cross-sub restore | `CCCTestDB_CrossSub` on target instance with 50 rows |
| Alerts | Failed backup job | Email received within 30 min |
| Alerts | Backup health event | Email received within 15 min |
| Alerts | Vault delete attempt | Email received within 5 min |
| Alerts | Security PIN retrieval | Email received within 5 min |
