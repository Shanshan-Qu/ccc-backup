<#
.SYNOPSIS
    CCC Azure Backup smoke test – triggers on-demand backups, uploads test data
    to the file share, and validates that all backup jobs complete successfully.

.DESCRIPTION
    Runs through the following steps automatically:
      1. Ensure Az PowerShell modules are present.
      2. Authenticate and set context to the target subscription.
      3. Upload a test file to the Azure File Share.
      4. Trigger on-demand backup for the file share and the non-prod VM.
      5. Wait for all jobs to complete (timeout: 30 minutes each).
      6. Print a pass/fail summary.

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
    [string] $VmName             = ""    # populated from terraform output if empty
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

function Record-Result([string]$tc, [string]$status, [string]$detail) {
    $results.Add([PSCustomObject]@{ TestCase = $tc; Status = $status; Detail = $detail })
    if ($status -eq "PASS") { Write-Pass "$tc – $detail" }
    else                     { Write-Fail "$tc – $detail" }
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

if ([string]::IsNullOrEmpty($StorageAccountName) -or [string]::IsNullOrEmpty($VmName)) {
    Write-Info "Reading terraform outputs to resolve resource names ..."
    $tfOutputRaw = terraform output -json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($null -ne $tfOutputRaw) {
        if ([string]::IsNullOrEmpty($StorageAccountName)) {
            $StorageAccountName = $tfOutputRaw.workload_storage_account_name.value
        }
        if ([string]::IsNullOrEmpty($VmName)) {
            $VmName = $tfOutputRaw.workload_vm_name.value
        }
    }
}

Write-Info "Storage account : $StorageAccountName"
Write-Info "File share      : $FileShareName"
Write-Info "VM name         : $VmName"

# ──────────────────────────────────────────────────────────────
# Step 3 – Upload test data to the Azure File Share
# ──────────────────────────────────────────────────────────────

Write-Step "TC001 – Uploading test file to '$FileShareName' in '$StorageAccountName'"

try {
    $storageKey = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroup -Name $StorageAccountName)[0].Value
    $storageCtx = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $storageKey

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
    ) + (1..50 | ForEach-Object { "Record $_: $(Get-Date -Format o -AsUTC) – sample workload data" })
    $content | Set-Content -Path $tmpFile -Encoding UTF8

    Set-AzStorageFileContent `
        -Context    $storageCtx `
        -ShareName  $FileShareName `
        -Source     $tmpFile `
        -Path       "backup-test/test-data-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt" `
        -Force | Out-Null

    Remove-Item $tmpFile -Force
    Record-Result "TC001" "PASS" "Test file uploaded to $FileShareName/backup-test/"
} catch {
    Record-Result "TC001" "FAIL" "Upload failed: $_"
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
try {
    $storageContainer = Get-AzRecoveryServicesBackupContainer `
        -ContainerType AzureStorage `
        -Status        Registered |
        Where-Object { $_.FriendlyName -like "*$StorageAccountName*" }

    if ($null -eq $storageContainer) {
        Record-Result "TC002" "FAIL" "Storage account '$StorageAccountName' is not registered with vault. Ensure azurerm_backup_protected_file_share was applied."
    } else {
        $filesItem = Get-AzRecoveryServicesBackupItem `
            -Container   $storageContainer `
            -WorkloadType AzureFiles |
            Where-Object { $_.FriendlyName -like "*$FileShareName*" }

        if ($null -eq $filesItem) {
            Record-Result "TC002" "FAIL" "File share '$FileShareName' not found in container '$($storageContainer.FriendlyName)'."
        } else {
            $expiryUtc  = (Get-Date).ToUniversalTime().AddDays(30)
            $filesJob   = Backup-AzRecoveryServicesBackupItem -Item $filesItem -ExpiryDateTimeUTC $expiryUtc
            Write-Info "On-demand backup triggered – Job ID: $($filesJob.JobId)"
            Record-Result "TC002" "PASS" "On-demand backup job started (Job ID: $($filesJob.JobId))"
        }
    }
} catch {
    Record-Result "TC002" "FAIL" "Error triggering file share backup: $_"
}

# ──────────────────────────────────────────────────────────────
# Step 6 – Trigger on-demand backup: VM
# ──────────────────────────────────────────────────────────────

Write-Step "TC003 – Triggering on-demand backup for VM '$VmName'"

$vmJob = $null
try {
    $vmContainer = Get-AzRecoveryServicesBackupContainer `
        -ContainerType AzureVM `
        -Status        Registered |
        Where-Object { $_.FriendlyName -like "*$VmName*" }

    if ($null -eq $vmContainer) {
        Record-Result "TC003" "FAIL" "VM '$VmName' is not registered with vault. Ensure azurerm_backup_protected_vm was applied."
    } else {
        $vmItem = Get-AzRecoveryServicesBackupItem `
            -Container    $vmContainer `
            -WorkloadType AzureVM

        if ($null -eq $vmItem) {
            Record-Result "TC003" "FAIL" "Backup item for VM '$VmName' not found in container."
        } else {
            $vmExpiryUtc = (Get-Date).ToUniversalTime().AddDays(7)
            $vmJob       = Backup-AzRecoveryServicesBackupItem -Item $vmItem -ExpiryDateTimeUTC $vmExpiryUtc
            Write-Info "On-demand VM backup triggered – Job ID: $($vmJob.JobId)"
            Record-Result "TC003" "PASS" "On-demand VM backup job started (Job ID: $($vmJob.JobId))"
        }
    }
} catch {
    Record-Result "TC003" "FAIL" "Error triggering VM backup: $_"
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

$r4 = Wait-BackupJob -Job $filesJob -Label "FileShare"
Record-Result "TC004" $r4.Status $r4.Detail

$r5 = Wait-BackupJob -Job $vmJob   -Label "VM"
Record-Result "TC005" $r5.Status $r5.Detail

# ──────────────────────────────────────────────────────────────
# Step 8 – Verify recovery points exist
# ──────────────────────────────────────────────────────────────

Write-Step "TC006 / TC007 – Verifying recovery points exist"

# File share recovery points
try {
    $storageContainer2 = Get-AzRecoveryServicesBackupContainer `
        -ContainerType AzureStorage -Status Registered |
        Where-Object { $_.FriendlyName -like "*$StorageAccountName*" }

    $filesItem2 = Get-AzRecoveryServicesBackupItem `
        -Container $storageContainer2 -WorkloadType AzureFiles |
        Where-Object { $_.FriendlyName -like "*$FileShareName*" }

    $rps = Get-AzRecoveryServicesBackupRecoveryPoint -Item $filesItem2

    if ($rps.Count -gt 0) {
        Record-Result "TC006" "PASS" "File share has $($rps.Count) recovery point(s). Latest: $($rps[0].RecoveryPointTime)"
    } else {
        Record-Result "TC006" "FAIL" "No recovery points found for file share '$FileShareName'."
    }
} catch {
    Record-Result "TC006" "FAIL" "Error checking file share recovery points: $_"
}

# VM recovery points
try {
    $vmContainer2 = Get-AzRecoveryServicesBackupContainer `
        -ContainerType AzureVM -Status Registered |
        Where-Object { $_.FriendlyName -like "*$VmName*" }

    $vmItem2 = Get-AzRecoveryServicesBackupItem `
        -Container $vmContainer2 -WorkloadType AzureVM

    $vmRps = Get-AzRecoveryServicesBackupRecoveryPoint -Item $vmItem2

    if ($vmRps.Count -gt 0) {
        Record-Result "TC007" "PASS" "VM has $($vmRps.Count) recovery point(s). Latest: $($vmRps[0].RecoveryPointTime)"
    } else {
        Record-Result "TC007" "FAIL" "No recovery points found for VM '$VmName'."
    }
} catch {
    Record-Result "TC007" "FAIL" "Error checking VM recovery points: $_"
}

# ──────────────────────────────────────────────────────────────
# Final Summary
# ──────────────────────────────────────────────────────────────

Write-Host "`n============================================================" -ForegroundColor White
Write-Host "  CCC Azure Backup Test Results" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor White

$results | Format-Table -AutoSize @{L="Test Case";E="TestCase"}, @{L="Status";E="Status"}, @{L="Detail";E="Detail"}

$passed = ($results | Where-Object Status -eq "PASS").Count
$failed = ($results | Where-Object Status -eq "FAIL").Count
$total  = $results.Count

Write-Host "  Passed : $passed / $total" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Yellow" })
if ($failed -gt 0) {
    Write-Host "  Failed : $failed / $total" -ForegroundColor Red
    exit 1
} else {
    Write-Host "  ALL TESTS PASSED" -ForegroundColor Green
    exit 0
}
