# CCC Azure Backup – Test Plan

> **Version**: 3.0  
> **Environment**: `ShanshanQu-NonProd` (subscription `634c603a-fa54-431f-8fdd-2279020b1cb9`)  
> **Region**: New Zealand North (`newzealandnorth`)  
> **Vault**: `rsv-ccc-backup-nzn-test` in `rg-rsv-backup-nzn`  
> **Alert notifications**: `shanshanqu@microsoft.com`

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

## 7. Pass / Fail Criteria

| Test | Pass Condition |
|------|---------------|
| VM on-demand backup | Job `Status = Completed`, ≥1 recovery point |
| VM file-level restore | Target file accessible with correct content |
| Azure Files on-demand backup | Job `Status = Completed`, ≥1 recovery point |
| Azure Files restore | Restored file present in `restored/` folder |
| Failed job alert | Email received within 30 min |
| Backup health alert | Email received within 15 min |
| Vault delete alert | Email received within 5 min |
| Security PIN alert | Email received within 5 min |
