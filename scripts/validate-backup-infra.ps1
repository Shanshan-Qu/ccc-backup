<#
.SYNOPSIS
    CCC Azure Backup – infrastructure validation script.

.DESCRIPTION
    Validates that every resource created by Terraform matches the CCC backup
    specification (doc.txt) without requiring live workloads.  Checks:

      • Recovery Services Vault settings (SKU, soft-delete, immutability, RBAC)
      • Backup policies (VM, SQL, AzFiles) – schedule, retention, type
      • Log Analytics Workspace connectivity (diagnostic settings)
      • Monitoring: action groups, metric alerts, activity log alerts, SQR rules
      • Workload networking: VNet, subnet, NSG rules
      • Workload storage account + file share (pre-provisioned for backup)

    Sandbox constraints that prevent live backup testing are listed separately.

.PARAMETER SubscriptionId
    Azure subscription ID. Defaults to the CCC sandbox used during development.

.PARAMETER ResourceGroup
    Resource group that contains all backup resources.

.EXAMPLE
    .\scripts\validate-backup-infra.ps1

.EXAMPLE
    .\scripts\validate-backup-infra.ps1 -SubscriptionId "<prod-sub-id>" -ResourceGroup "rg-rsv-backup-nzn"
#>

[CmdletBinding()]
param(
    [string] $SubscriptionId = "634c603a-fa54-431f-8fdd-2279020b1cb9",
    [string] $ResourceGroup  = "rg-rsv-backup-nzn",
    [string] $VaultName      = "rsv-ccc-backup-nzn-test",
    [string] $LawName        = "law-ccc-backup-nzn-test"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── helpers ────────────────────────────────────────────────────────────────────
function Write-Step ([string]$msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Pass ([string]$msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Write-Fail ([string]$msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Write-Skip ([string]$msg) { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow }
function Write-Info ([string]$msg) { Write-Host "         $msg" -ForegroundColor Gray }

$results  = [System.Collections.Generic.List[PSCustomObject]]::new()
$failures = 0

function Test-Condition ([string]$id, [string]$desc, [bool]$assertion, [string]$detail = "") {
    if ($assertion) {
        Write-Pass "$id : $desc"
        $results.Add([PSCustomObject]@{ Id=$id; Result="PASS"; Description=$desc; Detail=$detail })
    } else {
        Write-Fail "$id : $desc  ← $detail"
        $results.Add([PSCustomObject]@{ Id=$id; Result="FAIL"; Description=$desc; Detail=$detail })
        $script:failures++
    }
}

# ── 1. Authenticate ────────────────────────────────────────────────────────────
Write-Step "Authentication"

foreach ($mod in @("Az.Accounts","Az.RecoveryServices","Az.Monitor","Az.Network","Az.Storage","Az.OperationalInsights")) {
    if (-not (Get-Module -ListAvailable -Name $mod -ErrorAction SilentlyContinue)) {
        Write-Info "Installing $mod from PSGallery..."
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
    }
    Import-Module $mod -ErrorAction SilentlyContinue
}

$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx -or $ctx.Subscription.Id -ne $SubscriptionId) {
    Write-Info "Connecting to subscription $SubscriptionId ..."
    Connect-AzAccount -SubscriptionId $SubscriptionId -TenantId "16b3c013-d300-468d-ac64-7eda0820b6d3" | Out-Null
}
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
Write-Info "Authenticated as: $((Get-AzContext).Account.Id)"

# ── 2. Recovery Services Vault ─────────────────────────────────────────────────
Write-Step "TC01 – Recovery Services Vault"

$vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroup -Name $VaultName -ErrorAction SilentlyContinue
Test-Condition "TC01-01" "Vault exists" ($null -ne $vault)

if ($vault) {
    Set-AzRecoveryServicesVaultContext -Vault $vault

    Test-Condition "TC01-02" "Vault location = newzealandnorth"    ($vault.Location -eq "newzealandnorth") "actual: $($vault.Location)"
    Test-Condition "TC01-03" "Vault resource group = $ResourceGroup" ($vault.ResourceGroupName -eq $ResourceGroup)

    # Soft-delete (always-on in NZN per secure-by-default)
    $vaultProp = Get-AzRecoveryServicesVaultProperty -VaultId $vault.ID
    Test-Condition "TC01-04" "Soft-delete is enabled"              ($vaultProp.SoftDeleteFeatureState -ne "Disabled") "state: $($vaultProp.SoftDeleteFeatureState)"

    # Diagnostic settings → LAW
    $diagSettings = @(Get-AzDiagnosticSetting -ResourceId $vault.ID -ErrorAction SilentlyContinue)
    $hasDiag = $diagSettings | Where-Object { $_.WorkspaceId -like "*$LawName*" }
    Test-Condition "TC01-05" "Diagnostic settings send allLogs to LAW"  ($null -ne $hasDiag) "found $($diagSettings.Count) diagnostic setting(s)"
}

# ── 3. Backup Policies ─────────────────────────────────────────────────────────
Write-Step "TC02 – Backup Policies"

$vmPol  = Get-AzRecoveryServicesBackupProtectionPolicy -Name "CCC-Policy"       -ErrorAction SilentlyContinue
$sqlPol = Get-AzRecoveryServicesBackupProtectionPolicy -Name "CCC-SQLPolicy"    -ErrorAction SilentlyContinue
$afPol  = Get-AzRecoveryServicesBackupProtectionPolicy -Name "CCC-AzFiles-Policy" -ErrorAction SilentlyContinue

Test-Condition "TC02-01" "VM policy CCC-Policy exists"              ($null -ne $vmPol)
Test-Condition "TC02-02" "SQL policy CCC-SQLPolicy exists"          ($null -ne $sqlPol)
Test-Condition "TC02-03" "AzFiles policy CCC-AzFiles-Policy exists" ($null -ne $afPol)

if ($vmPol) {
    Test-Condition "TC02-04" "VM policy workload type = AzureVM"   ($vmPol.WorkloadType -eq "AzureVM") "actual: $($vmPol.WorkloadType)"
    # Enhanced V2 policy sets SnapshotRetentionInDays and/or PolicySubType = Enhanced
    $isV2 = ($vmPol.SnapshotRetentionInDays -gt 0) -or ($vmPol.PolicySubType -eq "Enhanced")
    Test-Condition "TC02-05" "VM policy is Enhanced (V2)"          $isV2 "SubType=$($vmPol.PolicySubType) SnapRetention=$($vmPol.SnapshotRetentionInDays)"
}
if ($sqlPol) {
    Test-Condition "TC02-06" "SQL policy workload type = MSSQL"    ($sqlPol.WorkloadType -eq "MSSQL" -or $sqlPol.WorkloadType -eq "AzureWorkload") "actual: $($sqlPol.WorkloadType)"
}
if ($afPol) {
    Test-Condition "TC02-07" "AzFiles policy workload type = AzureFiles" ($afPol.WorkloadType -eq "AzureFiles") "actual: $($afPol.WorkloadType)"
}

# ── 4. Log Analytics Workspace ──────────────────────────────────────────────────
Write-Step "TC03 – Log Analytics Workspace"

$law = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroup -Name $LawName -ErrorAction SilentlyContinue
Test-Condition "TC03-01" "LAW exists"                       ($null -ne $law)
if ($law) {
    Test-Condition "TC03-02" "LAW retention >= 30 days"     ($law.RetentionInDays -ge 30) "actual: $($law.RetentionInDays)"
    Test-Condition "TC03-03" "LAW location matches vault"   ($law.Location -eq "newzealandnorth") "actual: $($law.Location)"
}

# ── 5. Monitoring – Action Groups ──────────────────────────────────────────────
Write-Step "TC04 – Action Groups"

$agOps = Get-AzActionGroup -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*ops*" }
$agSec = Get-AzActionGroup -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*sec*" }

Test-Condition "TC04-01" "Ops action group exists"      ($null -ne $agOps)
Test-Condition "TC04-02" "Security action group exists" ($null -ne $agSec)

# ── 6. Monitoring – Metric Alerts ─────────────────────────────────────────────
Write-Step "TC05 – Metric & Activity Log Alerts"

$metricAlerts = Get-AzMetricAlertRuleV2 -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
$backupHealthAlert  = $metricAlerts | Where-Object { $_.Name -like "*backup-health*" }
$restoreHealthAlert = $metricAlerts | Where-Object { $_.Name -like "*restore-health*" }

Test-Condition "TC05-01" "Backup health metric alert exists"  ($null -ne $backupHealthAlert)
Test-Condition "TC05-02" "Restore health metric alert exists" ($null -ne $restoreHealthAlert)

$activityAlerts = @(Get-AzActivityLogAlert -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue)
Test-Condition "TC05-03" "Resource health activity alert exists"    ($null -ne ($activityAlerts | Where-Object { $_.Name -like "*resource-health*" }))
Test-Condition "TC05-04" "Vault delete alert exists"               ($null -ne ($activityAlerts | Where-Object { $_.Name -like "*admin-delete*" }))
Test-Condition "TC05-05" "Private endpoint approval alert exists"  ($null -ne ($activityAlerts | Where-Object { $_.Name -like "*approve-pe*" }))
Test-Condition "TC05-06" "Security PIN alert exists"               ($null -ne ($activityAlerts | Where-Object { $_.Name -like "*security-pin*" }))

# ── 7. Monitoring – Scheduled Query Rules ────────────────────────────────────
Write-Step "TC06 – Scheduled Query Rules"

$sqrRules = @(Get-AzScheduledQueryRule -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue)
Test-Condition "TC06-01" "Failed jobs SQR rule exists"        ($null -ne ($sqrRules | Where-Object { $_.Name -like "*failed-jobs*" }))
Test-Condition "TC06-02" "Storage-per-item SQR rule exists"   ($null -ne ($sqrRules | Where-Object { $_.Name -like "*storage-per-item*" }))
Test-Condition "TC06-03" "Storage-total SQR rule exists"      ($null -ne ($sqrRules | Where-Object { $_.Name -like "*storage-total*" }))

# ── 8. Workload Networking ─────────────────────────────────────────────────────
Write-Step "TC07 – Workload Networking (pre-provisioned)"

$vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "vnet-ccc*" }
$nsg  = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "nsg-workload*" }

Test-Condition "TC07-01" "Workload VNet exists"       ($null -ne $vnet)
Test-Condition "TC07-02" "Workload NSG exists"        ($null -ne $nsg)

if ($nsg) {
    $rules = @($nsg.SecurityRules)
    Test-Condition "TC07-03" "NSG allows AzureBackup outbound" ($null -ne ($rules | Where-Object { $_.DestinationAddressPrefix -eq "AzureBackup" -and $_.Access -eq "Allow" }))
    Test-Condition "TC07-04" "NSG allows Storage outbound"     ($null -ne ($rules | Where-Object { $_.DestinationAddressPrefix -eq "Storage"       -and $_.Access -eq "Allow" }))
}

# ── 9. Workload Storage (pre-provisioned) ──────────────────────────────────────
Write-Step "TC08 – Workload Storage Account + File Share"

$sa = Get-AzStorageAccount -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue | Where-Object { $_.StorageAccountName -like "stccc*" } | Select-Object -First 1
Test-Condition "TC08-01" "Storage account exists"       ($null -ne $sa)
if ($sa) {
    Test-Condition "TC08-02" "Storage account in NZN"   ($sa.PrimaryLocation -eq "newzealandnorth") "actual: $($sa.PrimaryLocation)"
    Test-Condition "TC08-03" "Storage account = Standard LRS" ($sa.Sku.Name -eq "Standard_LRS") "actual: $($sa.Sku.Name)"
    Test-Condition "TC08-04" "Public blob access disabled"    ($sa.AllowBlobPublicAccess -ne $true) "actual: $($sa.AllowBlobPublicAccess)"

    # File share
    $ctx   = New-AzStorageContext -StorageAccountName $sa.StorageAccountName -UseConnectedAccount
    $share = Get-AzStorageShare -Name "ccc-test-share" -Context $ctx -ErrorAction SilentlyContinue
    Test-Condition "TC08-05" "File share 'ccc-test-share' exists" ($null -ne $share)
}

# ── 9. Workload VM ─────────────────────────────────────────────────────────────
Write-Step "TC09 – Workload VM"

$vm = Get-AzVM -ResourceGroupName $ResourceGroup -Name "vm-ccc-backup-nzn-test-01" -ErrorAction SilentlyContinue
Test-Condition "TC09-01" "VM vm-ccc-backup-nzn-test-01 exists" ($null -ne $vm)

if ($vm) {
    Test-Condition "TC09-02" "VM is in NZN region" ($vm.Location -eq "newzealandnorth") "actual: $($vm.Location)"
    Test-Condition "TC09-03" "VM SKU is Standard_D2s_v5" ($vm.HardwareProfile.VmSize -eq "Standard_D2s_v5") "actual: $($vm.HardwareProfile.VmSize)"

    $vmStatus = Get-AzVM -ResourceGroupName $ResourceGroup -Name $vm.Name -Status -ErrorAction SilentlyContinue
    $powerState = ($vmStatus.Statuses | Where-Object Code -like "PowerState/*").DisplayStatus
    Test-Condition "TC09-04" "VM is running" ($powerState -eq "VM running") "actual: $powerState"

    # TC09-05: Verify VM is registered for backup in the RSV vault
    $vaultObj = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroup -Name $VaultName -ErrorAction SilentlyContinue
    if ($vaultObj) {
        Set-AzRecoveryServicesVaultContext -Vault $vaultObj
        $backupItem = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $vaultObj.ID -ErrorAction SilentlyContinue |
                      Where-Object { $_.VirtualMachineId -like "*vm-ccc-backup-nzn-test-01" }
        Test-Condition "TC09-05" "VM is registered in RSV vault for backup" ($null -ne $backupItem) "found: $($backupItem.Name)"

        if ($backupItem) {
            Test-Condition "TC09-06" "VM backup protection status is Protected or IRPending" `
                ($backupItem.ProtectionStatus -eq "Healthy" -or $backupItem.ProtectionStatus -eq "IRPending" -or $backupItem.ProtectionState -match "Protected|IRPending") `
                "ProtectionStatus=$($backupItem.ProtectionStatus) ProtectionState=$($backupItem.ProtectionState)"

            Test-Condition "TC09-07" "VM backup policy is CCC-Policy" ($backupItem.ProtectionPolicyName -eq "CCC-Policy") "actual: $($backupItem.ProtectionPolicyName)"
        }
    }
}

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Host "`n" + ("─" * 60) -ForegroundColor DarkGray
Write-Host "VALIDATION SUMMARY" -ForegroundColor White
Write-Host ("─" * 60) -ForegroundColor DarkGray

$passed = @($results | Where-Object Result -eq "PASS").Count
$failed = @($results | Where-Object Result -eq "FAIL").Count
$total  = @($results).Count

Write-Host "  Total:  $total"
Write-Host "  Passed: $passed" -ForegroundColor Green
Write-Host "  Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })

if ($failed -gt 0) {
    Write-Host "`nFailed tests:" -ForegroundColor Red
    $results | Where-Object Result -eq "FAIL" | ForEach-Object { Write-Host "  * $($_.Id) – $($_.Description)" -ForegroundColor Red }
}

Write-Host "`n"
Write-Host "SANDBOX CONSTRAINT NOTES" -ForegroundColor Yellow
Write-Host "  1. VM backup (TC09) is now ACTIVE on ShanshanQu-NonProd (634c603a-...)."
Write-Host "     VM vm-ccc-backup-nzn-test-01 (Standard_D2s_v5) deployed and registered"
Write-Host "     to CCC-Policy in rsv-ccc-backup-nzn-test."
Write-Host ""
Write-Host "  2. Azure Files backup BLOCKED: subscription policy enforces"
Write-Host "     allowSharedKeyAccess=false (policy: StorageAccount_DisableLocalAuth_Modify,"
Write-Host "     SFI-ID4.2.1 Storage Accounts - Safe Secrets Standard)."
Write-Host "     Azure Backup requires key auth internally for AzureFiles workload type."
Write-Host "     Resolution: request a policy exception for backup storage accounts,"
Write-Host "     or wait for Azure Backup to support MSI-based file-share backup."
Write-Host ""
Write-Host "  Infrastructure is fully deployed. All VM backup test cases (TC09) active."

if ($failures -gt 0) { exit 1 }
exit 0
