<#
.SYNOPSIS
    CCC Azure Backup smoke test – seeds test data, triggers on-demand backups
    for Azure Files, Linux VM, and SQL Server, and validates all jobs complete.

.DESCRIPTION
    Runs through the following steps automatically:
      1.  Ensure Az PowerShell modules are present.
      2.  Authenticate and set context to the target subscription.
      3.  Seed test data: upload files to the Azure File Share.
      4.  Seed test data: create CCCTestDB on the SQL VM with 50 rows.
      5.  Trigger on-demand backup for the file share.
      6.  Trigger on-demand backup for the non-prod Linux VM.
      7.  Register the SQL VM workload container and enable DB protection.
      8.  Trigger on-demand full backup for CCCTestDB.
      9.  Wait for all jobs to complete (timeout: 60 min each).
      10. Verify recovery points exist for each workload.
      11. Print a pass/fail summary.

.PARAMETER SubscriptionId
    The Azure subscription ID. Defaults to the CCC test subscription.

.PARAMETER ResourceGroup
    Resource group that contains the vault. Default: rg-rsv-backup-nzn.

.PARAMETER VaultName
    Recovery Services vault name. Default: rsv-ccc-backup-nzn-test.

.PARAMETER StorageAccountName
    Storage account name – auto-read from terraform output if left empty.

.PARAMETER FileShareName
    Azure File Share name. Default: ccc-test-share.

.PARAMETER VmName
    Non-prod VM name – auto-read from terraform output if left empty.

.EXAMPLE
    .\scripts\run-backup-test.ps1

.EXAMPLE
    .\scripts\run-backup-test.ps1 -StorageAccountName stcccabc123 -VmName vm-ccc-backup-nzn-test-01
#>

[CmdletBinding()]
param(
    [string] $SubscriptionId    = "634c603a-fa54-431f-8fdd-2279020b1cb9",
    [string] $ResourceGroup     = "rg-rsv-backup-nzn",
    [string] $VaultName         = "rsv-ccc-backup-nzn-test",
    [string] $StorageAccountName = "",   # populated from terraform output if empty
    [string] $FileShareName      = "ccc-test-share",
    [string] $VmName             = "",   # populated from terraform output if empty
    [string] $SqlVmName          = "",   # populated from terraform output if empty
    [switch] $FailedOnly                 # when set, only re-run TCs that failed in the previous run
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ──────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────

function Write-Step([string]$msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function Write-Pass([string]$msg) { Write-Host "[PASS] $msg" -ForegroundColor Green }
function Write-Fail([string]$msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red }
function Write-Info([string]$msg) { Write-Host "      $msg" -ForegroundColor Gray }

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# Path where results are saved/loaded for -FailedOnly re-runs
$resultsFile = Join-Path $PSScriptRoot "test-results.json"

# In FailedOnly mode, load the previous run's results and skip TCs that already passed
$prevPassed = @{}
if ($FailedOnly -and (Test-Path $resultsFile)) {
    $prevResults = Get-Content $resultsFile -Raw | ConvertFrom-Json
    foreach ($r in $prevResults) {
        if ($r.Status -eq "PASS") { $prevPassed[$r.TestCase] = $r.Detail }
    }
    Write-Host "  FailedOnly: $($prevPassed.Count) TC(s) carried forward from previous run." -ForegroundColor DarkGray
} elseif ($FailedOnly) {
    Write-Host "  FailedOnly: no previous results found at $resultsFile – running all TCs." -ForegroundColor Yellow
}

function Write-TestResult([string]$tc, [string]$status, [string]$detail) {
    $results.Add([PSCustomObject]@{ TestCase = $tc; Status = $status; Detail = $detail })
    if ($status -eq "PASS") { Write-Pass "$tc – $detail" }
    else                     { Write-Fail "$tc – $detail" }
}

# Returns $true if the TC should run; in FailedOnly mode carries forward the previous PASS result
function Test-ShouldRun([string]$tc) {
    if (-not $FailedOnly) { return $true }
    if ($prevPassed.ContainsKey($tc)) {
        $results.Add([PSCustomObject]@{ TestCase = $tc; Status = "PASS"; Detail = "(prev run) $($prevPassed[$tc])" })
        Write-Host "  [SKIP] $tc – passed in previous run." -ForegroundColor DarkGray
        return $false
    }
    return $true
}

# ──────────────────────────────────────────────────────────────
# Step 1 – Ensure required Az modules are installed
# ──────────────────────────────────────────────────────────────

Write-Step "Checking Az PowerShell modules"

$requiredModules = @("Az.Accounts", "Az.RecoveryServices", "Az.Storage")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Info "Installing $mod ..."
        Install-Module -Name $mod -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
    } else {
        Write-Info "$mod already installed."
    }
}

Import-Module Az.Accounts, Az.RecoveryServices, Az.Storage -ErrorAction Stop

# ──────────────────────────────────────────────────────────────
# Step 2 – Authenticate and set subscription context
# ──────────────────────────────────────────────────────────────

Write-Step "Setting Azure context (subscription: $SubscriptionId)"

try {
    $ctx = Get-AzContext
    if ($null -eq $ctx -or $ctx.Subscription.Id -ne $SubscriptionId) {
        Write-Info "No matching context found – connecting interactively ..."
        Connect-AzAccount -Subscription $SubscriptionId | Out-Null
    }
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    Write-Info "Context set: $((Get-AzContext).Subscription.Name)"
} catch {
    Write-Fail "Authentication failed: $_"
    exit 1
}

# ──────────────────────────────────────────────────────────────
# Step 2b – Resolve resource names from terraform output if needed
# ──────────────────────────────────────────────────────────────

# Resolve terraform binary: prefer one on PATH, fall back to known install location
$tfExe = Get-Command terraform -ErrorAction SilentlyContinue |
             Select-Object -ExpandProperty Source
if (-not $tfExe) {
    $tfExe = "C:\Users\shanshanqu\bin\terraform\terraform.exe"
    if (-not (Test-Path $tfExe)) {
        Write-Fail "terraform not found on PATH and not at $tfExe. Add terraform to your PATH and retry."
        exit 1
    }
    Write-Info "terraform not on PATH – using $tfExe"
}

if ([string]::IsNullOrEmpty($StorageAccountName) -or [string]::IsNullOrEmpty($VmName) -or [string]::IsNullOrEmpty($SqlVmName)) {
    Write-Info "Reading terraform outputs to resolve resource names ..."
    $tfOutputRaw = & $tfExe output -json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($null -ne $tfOutputRaw) {
        if ([string]::IsNullOrEmpty($StorageAccountName)) {
            $StorageAccountName = $tfOutputRaw.workload_storage_account_name.value
        }
        if ([string]::IsNullOrEmpty($VmName)) {
            $VmName = $tfOutputRaw.workload_vm_name.value
        }
    }
}

if ([string]::IsNullOrEmpty($SqlVmName) -and $null -ne $tfOutputRaw) {
    $SqlVmName = $tfOutputRaw.sql_vm_name.value
}

# Resolve SQL admin credentials from Terraform output (set by azurerm_mssql_virtual_machine)
$SqlAdminLogin    = if ($null -ne $tfOutputRaw) { $tfOutputRaw.sql_admin_login.value }    else { "ccc_sqladmin" }
$SqlAdminPassword = if ($null -ne $tfOutputRaw) { & $tfExe output -raw sql_admin_password 2>$null } else { "" }

Write-Info "Storage account : $StorageAccountName"
Write-Info "File share      : $FileShareName"
Write-Info "VM name         : $VmName"
Write-Info "SQL VM name     : $SqlVmName"

# ──────────────────────────────────────────────────────────────
# Step 3 – Upload test data to the Azure File Share
# ──────────────────────────────────────────────────────────────

Write-Step "TC001 – Uploading test file to '$FileShareName' in '$StorageAccountName'"

if (Test-ShouldRun "TC001") {
    try {
        # Use OAuth (Azure AD) with backup request intent flag (required for Storage File Data Privileged Contributor)
        $storageCtx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount -EnableFileBackupRequestIntent

    # Create test directory
    try { New-AzStorageDirectory -Context $storageCtx -ShareName $FileShareName -Path "backup-test" | Out-Null }
    catch { Write-Info "Directory may already exist – continuing." }

    # Write temp file and upload
    $tmpFile = [System.IO.Path]::GetTempFileName()
    $content = @(
        "=== CCC Azure Backup Test File ==="
        "Uploaded: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ' -AsUTC)"
        "SubscriptionId: $SubscriptionId"
        "VaultName: $VaultName"
        ""
        "This file was created by run-backup-test.ps1 to validate that the"
        "Azure Files backup policy (CCC-AzFiles-Policy) is protecting data"
        "in share '$FileShareName' within storage account '$StorageAccountName'."
        ""
    ) + (1..50 | ForEach-Object { "Record {0}: {1} - sample workload data" -f $_, (Get-Date -Format o -AsUTC) })
    $content | Set-Content -Path $tmpFile -Encoding UTF8

    Set-AzStorageFileContent `
        -Context    $storageCtx `
        -ShareName  $FileShareName `
        -Source     $tmpFile `
        -Path       "backup-test/test-data-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt" `
        -Force | Out-Null

        Remove-Item $tmpFile -Force
        Write-TestResult "TC001" "PASS" "Test file uploaded to $FileShareName/backup-test/"
    } catch {
        Write-TestResult "TC001" "FAIL" "Upload failed: $_"
    }
}

# ──────────────────────────────────────────────────────────────
# Step 3b – Seed CCCTestDB on the SQL VM
# ──────────────────────────────────────────────────────────────

Write-Step "TC002-SQL-Seed – Creating CCCTestDB and seeding 50 rows on SQL VM '$SqlVmName'"

if (Test-ShouldRun "TC002-SQL-Seed") {
    try {
        if ([string]::IsNullOrEmpty($SqlVmName)) {
            Write-TestResult "TC002-SQL-Seed" "FAIL" "SqlVmName is empty – pass -SqlVmName or ensure terraform output sql_vm_name is set."
        } else {
            # Write SQL seeding script to a temp file so quoting is not an issue
            $sqlSeedScript = Join-Path $env:TEMP "ccc-sql-seed-$([System.Guid]::NewGuid()).ps1"
            @"
sqlcmd -S localhost -U $SqlAdminLogin -P "$SqlAdminPassword" -Q "IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'CCCTestDB') CREATE DATABASE CCCTestDB"
if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
sqlcmd -S localhost -U $SqlAdminLogin -P "$SqlAdminPassword" -d CCCTestDB -Q "IF OBJECT_ID('dbo.BackupTestRecords') IS NULL CREATE TABLE dbo.BackupTestRecords (Id INT IDENTITY PRIMARY KEY, RecordName NVARCHAR(100) NOT NULL, SeededAt DATETIME2 DEFAULT SYSUTCDATETIME(), Payload NVARCHAR(MAX))"
if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
sqlcmd -S localhost -U $SqlAdminLogin -P "$SqlAdminPassword" -d CCCTestDB -Q "DECLARE @i INT=1; WHILE @i<=50 BEGIN INSERT dbo.BackupTestRecords(RecordName,Payload) VALUES(CONCAT('CCC-Record-',FORMAT(@i,'000')),CONCAT('{""""index"""":',@i,'}'));SET @i=@i+1 END; SELECT COUNT(*) AS TotalRows FROM dbo.BackupTestRecords"
"@ | Set-Content $sqlSeedScript -Encoding UTF8

            $seedResult = Invoke-AzVMRunCommand `
                -ResourceGroupName $ResourceGroup `
                -VMName            $SqlVmName `
                -CommandId         RunPowerShellScript `
                -ScriptPath        $sqlSeedScript
            Remove-Item $sqlSeedScript -Force -ErrorAction SilentlyContinue

            $seedOutput = $seedResult.Value[0].Message
            if ($seedOutput -match 'TotalRows') {
                Write-TestResult "TC002-SQL-Seed" "PASS" "CCCTestDB created and seeded. Output: $($seedOutput -replace '\r?\n',' ')"
            } else {
                Write-TestResult "TC002-SQL-Seed" "FAIL" "Unexpected seed output: $seedOutput"
            }
        }
    } catch {
        Write-TestResult "TC002-SQL-Seed" "FAIL" "SQL seeding failed: $_"
    }
}

# ──────────────────────────────────────────────────────────────
# Step 4 – Set vault context
# ──────────────────────────────────────────────────────────────

Write-Step "Connecting to vault context ($VaultName)"

$vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroup -Name $VaultName
Set-AzRecoveryServicesVaultContext -Vault $vault

# ──────────────────────────────────────────────────────────────
# Step 5 – Trigger on-demand backup: Azure File Share
# ──────────────────────────────────────────────────────────────

Write-Step "TC002 – Triggering on-demand backup for file share '$FileShareName'"

$filesJob = $null
if (Test-ShouldRun "TC002") {
    try {
    $storageContainer = Get-AzRecoveryServicesBackupContainer `
        -ContainerType AzureStorage |
        Where-Object { $_.FriendlyName -like "*$StorageAccountName*" }

    if ($null -eq $storageContainer) {
        Write-TestResult "TC002" "FAIL" "Storage account '$StorageAccountName' is not registered with vault. Ensure azurerm_backup_protected_file_share was applied."
    } else {
        $filesItem = Get-AzRecoveryServicesBackupItem `
            -Container   $storageContainer `
            -WorkloadType AzureFiles |
            Where-Object { $_.FriendlyName -like "*$FileShareName*" }

        if ($null -eq $filesItem) {
            Write-TestResult "TC002" "FAIL" "File share '$FileShareName' not found in container '$($storageContainer.FriendlyName)'."
        } else {
            $expiryUtc  = (Get-Date).ToUniversalTime().AddDays(30)
            $filesJob   = Backup-AzRecoveryServicesBackupItem -Item $filesItem -ExpiryDateTimeUTC $expiryUtc
            Write-Info "On-demand backup triggered – Job ID: $($filesJob.JobId)"
            Write-TestResult "TC002" "PASS" "On-demand backup job started (Job ID: $($filesJob.JobId))"
        }
    }
    } catch {
        Write-TestResult "TC002" "FAIL" "Error triggering file share backup: $_"
    }
}

# ──────────────────────────────────────────────────────────────
# Step 6 – Trigger on-demand backup: VM
# ──────────────────────────────────────────────────────────────

Write-Step "TC003 – Triggering on-demand backup for VM '$VmName'"

$vmJob = $null
if (Test-ShouldRun "TC003") {
    try {
    $vmContainer = Get-AzRecoveryServicesBackupContainer `
        -ContainerType AzureVM |
        Where-Object { $_.FriendlyName -like "*$VmName*" }

    if ($null -eq $vmContainer) {
        Write-TestResult "TC003" "FAIL" "VM '$VmName' is not registered with vault. Ensure azurerm_backup_protected_vm was applied."
    } else {
        $vmItem = Get-AzRecoveryServicesBackupItem `
            -Container    $vmContainer `
            -WorkloadType AzureVM

        if ($null -eq $vmItem) {
            Write-TestResult "TC003" "FAIL" "Backup item for VM '$VmName' not found in container."
        } else {
            $vmExpiryUtc = (Get-Date).ToUniversalTime().AddDays(7)
            $vmJob       = Backup-AzRecoveryServicesBackupItem -Item $vmItem -ExpiryDateTimeUTC $vmExpiryUtc
            Write-Info "On-demand VM backup triggered – Job ID: $($vmJob.JobId)"
            Write-TestResult "TC003" "PASS" "On-demand VM backup job started (Job ID: $($vmJob.JobId))"
        }
    }
    } catch {
        Write-TestResult "TC003" "FAIL" "Error triggering VM backup: $_"
    }
}

# ──────────────────────────────────────────────────────────────
# Step 7 – Wait for jobs to complete (30-minute timeout)
# ──────────────────────────────────────────────────────────────

Write-Step "TC004 / TC005 – Waiting for backup jobs to complete (timeout: 30 min)"

function Wait-BackupJob {
    param([object]$Job, [string]$Label, [int]$TimeoutMinutes = 30)

    if ($null -eq $Job) { return @{ Status = "SKIPPED"; Detail = "No job to wait for." } }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-Info "Waiting for $Label job $($Job.JobId) ..."

    do {
        Start-Sleep -Seconds 30
        $refreshed = Get-AzRecoveryServicesBackupJob -JobId $Job.JobId
        Write-Info "  [$Label] Status: $($refreshed.Status) | Duration: $($refreshed.Duration)"
    } while ($refreshed.Status -in @("InProgress", "Pending") -and (Get-Date) -lt $deadline)

    if ($refreshed.Status -eq "Completed") {
        return @{ Status = "PASS"; Detail = "$Label completed in $($refreshed.Duration)." }
    } elseif ((Get-Date) -ge $deadline) {
        return @{ Status = "FAIL"; Detail = "$Label timed out after $TimeoutMinutes minutes. Last status: $($refreshed.Status)." }
    } else {
        return @{ Status = "FAIL"; Detail = "$Label ended with status '$($refreshed.Status)'. Error: $($refreshed.ErrorDetails)." }
    }
}

if (Test-ShouldRun "TC004") {
    $r4 = Wait-BackupJob -Job $filesJob -Label "FileShare"
    Write-TestResult "TC004" $r4.Status $r4.Detail
}

if (Test-ShouldRun "TC005") {
    $r5 = Wait-BackupJob -Job $vmJob -Label "VM"
    Write-TestResult "TC005" $r5.Status $r5.Detail
}

# ──────────────────────────────────────────────────────────────
# Step 7b – Register SQL workload container, enable protection,
#            and trigger on-demand SQL full backup
# ──────────────────────────────────────────────────────────────

Write-Step "TC006-SQL – Registering SQL VM workload container and triggering SQL backup"

$sqlJob = $null
if (Test-ShouldRun "TC006-SQL") {
    try {
    if ([string]::IsNullOrEmpty($SqlVmName)) {
        Write-TestResult "TC006-SQL" "FAIL" "SqlVmName is empty – skipping SQL backup steps."
    } else {
        # Register the SQL VM as an AzureVMAppContainer
        $sqlVmId = az vm show -g $ResourceGroup -n $SqlVmName --query id -o tsv
        Register-AzRecoveryServicesBackupContainer `
            -ResourceId           $sqlVmId `
            -BackupManagementType AzureWorkload `
            -WorkloadType         MSSQL `
            -VaultId              $vault.ID `
            -Force | Out-Null

        # Discover SQL databases
        $sqlContainer = Get-AzRecoveryServicesBackupContainer `
            -ContainerType AzureVMAppContainer `
            -VaultId       $vault.ID |`
            Where-Object { $_.FriendlyName -like "*$SqlVmName*" }

        if ($null -eq $sqlContainer) {
            Write-TestResult "TC006-SQL" "FAIL" "SQL VM container not found after registration."
        } else {
            Initialize-AzRecoveryServicesBackupProtectableItem `
                -WorkloadType MSSQL -VaultId $vault.ID -Container $sqlContainer | Out-Null

            $dbItem = Get-AzRecoveryServicesBackupProtectableItem `
                -WorkloadType MSSQL -ItemType SQLDataBase -VaultId $vault.ID -ErrorAction SilentlyContinue |`
                Where-Object { $_.ServerName -like "*$SqlVmName*" -and $_.FriendlyName -eq "CCCTestDB" }

            if ($null -eq $dbItem) {
                Write-TestResult "TC006-SQL" "FAIL" "CCCTestDB not discovered on '$SqlVmName'. Ensure the database was seeded and the SQL IaaS extension is registered."
            } else {
                # Enable protection
                $sqlPolicy = Get-AzRecoveryServicesBackupProtectionPolicy `
                    -Name "CCC-SQL-Workload-Policy" -VaultId $vault.ID
                Enable-AzRecoveryServicesBackupProtection `
                    -ProtectableItem $dbItem -Policy $sqlPolicy -VaultId $vault.ID | Out-Null

                # Trigger on-demand full backup
                $sqlItem = Get-AzRecoveryServicesBackupItem `
                    -WorkloadType MSSQL -BackupManagementType AzureWorkload `
                    -VaultId $vault.ID |`
                    Where-Object { $_.FriendlyName -eq "CCCTestDB" }

                $sqlJob = Backup-AzRecoveryServicesBackupItem `
                    -Item $sqlItem -BackupType Full `
                    -ExpiryDateTimeUTC (Get-Date).ToUniversalTime().AddDays(7) `
                    -VaultId $vault.ID
                Write-TestResult "TC006-SQL" "PASS" "SQL full backup triggered – Job ID: $($sqlJob.JobId)"
            }
        }
    }
    } catch {
        Write-TestResult "TC006-SQL" "FAIL" "SQL backup setup failed: $_"
    }
}

# Wait for SQL job
Write-Step "TC007-SQL – Waiting for SQL backup job to complete (timeout: 60 min)"
if (Test-ShouldRun "TC007-SQL") {
    $r7 = Wait-BackupJob -Job $sqlJob -Label "SQLFullBackup" -TimeoutMinutes 60
    Write-TestResult "TC007-SQL" $r7.Status $r7.Detail
}

# ──────────────────────────────────────────────────────────────
# Step 8 – Verify recovery points exist
# ──────────────────────────────────────────────────────────────

Write-Step "TC006 / TC007 – Verifying recovery points exist"

# File share recovery points
if (Test-ShouldRun "TC006") {
    try {
    $storageContainer2 = Get-AzRecoveryServicesBackupContainer `
        -ContainerType AzureStorage |
        Where-Object { $_.FriendlyName -like "*$StorageAccountName*" }

    $filesItem2 = Get-AzRecoveryServicesBackupItem `
        -Container $storageContainer2 -WorkloadType AzureFiles |
        Where-Object { $_.FriendlyName -like "*$FileShareName*" }

    $rps = @(Get-AzRecoveryServicesBackupRecoveryPoint -Item $filesItem2)

    if ($rps.Count -gt 0) {
        Write-TestResult "TC006" "PASS" "File share has $($rps.Count) recovery point(s). Latest: $($rps[0].RecoveryPointTime)"
    } else {
        Write-TestResult "TC006" "FAIL" "No recovery points found for file share '$FileShareName'."
    }
    } catch {
        Write-TestResult "TC006" "FAIL" "Error checking file share recovery points: $_"
    }
}

# VM recovery points
if (Test-ShouldRun "TC007") {
    try {
    $vmContainer2 = Get-AzRecoveryServicesBackupContainer `
        -ContainerType AzureVM |
        Where-Object { $_.FriendlyName -like "*$VmName*" }

    $vmItem2 = Get-AzRecoveryServicesBackupItem `
        -Container $vmContainer2 -WorkloadType AzureVM

    $vmRps = @(Get-AzRecoveryServicesBackupRecoveryPoint -Item $vmItem2)

    if ($vmRps.Count -gt 0) {
        Write-TestResult "TC007" "PASS" "VM has $($vmRps.Count) recovery point(s). Latest: $($vmRps[0].RecoveryPointTime)"
    } else {
        Write-TestResult "TC007" "FAIL" "No recovery points found for VM '$VmName'."
    }
    } catch {
        Write-TestResult "TC007" "FAIL" "Error checking VM recovery points: $_"
    }
}

# SQL recovery points
if (Test-ShouldRun "TC008") {
    try {
    if (-not [string]::IsNullOrEmpty($SqlVmName)) {
        $sqlItem2 = Get-AzRecoveryServicesBackupItem `
            -WorkloadType MSSQL -BackupManagementType AzureWorkload `
            -VaultId $vault.ID |`
            Where-Object { $_.FriendlyName -eq "CCCTestDB" }

        if ($null -ne $sqlItem2) {
            $sqlRps = @(Get-AzRecoveryServicesBackupRecoveryPoint -Item $sqlItem2 -VaultId $vault.ID)
            if ($sqlRps.Count -gt 0) {
                Write-TestResult "TC008" "PASS" "CCCTestDB has $($sqlRps.Count) recovery point(s). Latest: $($sqlRps[0].RecoveryPointTime)"
            } else {
                Write-TestResult "TC008" "FAIL" "No recovery points found for CCCTestDB."
            }
        } else {
            Write-TestResult "TC008" "FAIL" "CCCTestDB backup item not found – SQL backup may not have completed."
        }
    } else {
        Write-TestResult "TC008" "FAIL" "SqlVmName is empty – SQL recovery point check skipped."
    }
    } catch {
        Write-TestResult "TC008" "FAIL" "Error checking SQL recovery points: $_"
    }
}

# Save results for -FailedOnly re-runs
$results | ConvertTo-Json -Depth 5 | Set-Content $resultsFile -Encoding UTF8
Write-Info "Results saved to $resultsFile"

# ──────────────────────────────────────────────────────────────
# Final Summary
# ──────────────────────────────────────────────────────────────

Write-Host "`n============================================================" -ForegroundColor White
Write-Host "  CCC Azure Backup Test Results" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor White

$results | Format-Table -AutoSize @{L="Test Case";E="TestCase"}, @{L="Status";E="Status"}, @{L="Detail";E="Detail"}

$passed = @($results | Where-Object { $_.Status -eq "PASS" }).Count
$failed = @($results | Where-Object { $_.Status -eq "FAIL" }).Count
$total  = $results.Count

Write-Host "  Passed : $passed / $total" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Yellow" })
if ($failed -gt 0) {
    Write-Host "  Failed : $failed / $total" -ForegroundColor Red
    exit 1
} else {
    Write-Host "  ALL TESTS PASSED" -ForegroundColor Green
    exit 0
}
