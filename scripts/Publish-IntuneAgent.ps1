[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ $_ -ne [guid]::Empty })]
    [guid]$TargetSecurityGroupId = [guid]::Empty
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Authentication
$tenantId = '11111111-1111-1111-1111-111111111111' # Replace with your Entra tenant ID.
$context = Get-MgContext
if (-not $context -or $context.TenantId -ne $tenantId -or $context.Account -ine 'admin@contoso.example') { # Replace with your authorized administrator UPN.
    throw 'Run Get-EnrollmentInventory.ps1 -DeploymentAccess with the Contoso account first.'
}
foreach ($scope in @('DeviceManagementScripts.ReadWrite.All', 'Group.ReadWrite.All', 'Device.Read.All', 'DeviceManagementManagedDevices.Read.All')) {
    if ($scope -notin $context.Scopes) { throw "Missing delegated permission: $scope" }
}

function Get-GraphCollection {
    param([string]$Uri)
    while ($Uri) {
        if (-not $Uri.StartsWith('https://graph.microsoft.com/', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected Graph host.' }
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject
        foreach ($item in $page.value) { $item }
        $Uri = $page.'@odata.nextLink'
    }
}

function Send-GraphJson {
    param([string]$Method, [string]$Uri, $Body)
    Invoke-MgGraphRequest -Method $Method -Uri $Uri -Body ($Body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -OutputType PSObject
}

function Get-ValidatedTargetGroup {
    param([guid]$GroupId)

    $group = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId" -OutputType PSObject
    if ($group.id -ine $GroupId.ToString() -or -not $group.securityEnabled -or $group.mailEnabled -or @($group.groupTypes).Count) {
        throw 'Target must be an existing assigned-membership, non-mail-enabled security group.'
    }
    $members = @(Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/members")
    if (-not $members.Count) { throw 'Target security group is empty. Add verified Intune Windows device objects before publishing.' }
    $managedDevices = @(Get-GraphCollection -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$select=id,azureADDeviceId,operatingSystem')
    foreach ($member in $members) {
        if ($member.'@odata.type' -ne '#microsoft.graph.device') { throw 'Target group must contain only direct device members; users and nested groups are not supported.' }
        $device = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/devices/$($member.id)" -OutputType PSObject
        $deviceId = [guid]::Empty
        if (-not $device.accountEnabled -or $device.operatingSystem -ne 'Windows' -or
            -not [guid]::TryParse([string]$device.deviceId, [ref]$deviceId) -or $deviceId -eq [guid]::Empty) {
            throw "Target group member $($member.id) is not an enabled Windows device with a valid Entra device ID."
        }
        $managed = @($managedDevices | Where-Object { $_.azureADDeviceId -ieq $device.deviceId -and $_.operatingSystem -eq 'Windows' })
        if (-not $managed.Count) { throw "Target group member $($member.id) has no matching Intune-managed Windows device. Review its directory identity." }
    }
    return $group
}

if ($TargetSecurityGroupId -ne [guid]::Empty) {
    $group = Get-ValidatedTargetGroup -GroupId $TargetSecurityGroupId
    $groupName = $group.displayName
    $marker = "ContosoDeviceMonitoring; security-group AMA client deployment; group=$TargetSecurityGroupId"
}
else {
    $managedId = '55555555-5555-5555-5555-555555555555' # Replace with the Intune managed-device ID.
    $directoryId = '66666666-6666-6666-6666-666666666666' # Replace with the mapped Entra directory object ID, not the device ID.
    $registeredId = '44444444-4444-4444-4444-444444444444' # Replace with the Entra device ID mapped by Intune.
    $managed = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$managedId" -OutputType PSObject
    if ($managed.deviceName -ine 'CONTOSO-PC' -or $managed.azureADDeviceId -ne $registeredId -or $managed.operatingSystem -ne 'Windows') { # Replace with the target computer name.
        throw 'Intune device identity changed. Review inventory before deployment.'
    }
    $directory = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/devices/$directoryId" -OutputType PSObject
    if ($directory.deviceId -ne $registeredId -or -not $directory.accountEnabled) { throw 'Unexpected or disabled directory device.' }
}
$installerPath = Join-Path $PSScriptRoot 'Install-AzureMonitorAgent.ps1'
$bytes = [IO.File]::ReadAllBytes($installerPath)
if ($bytes.Length -ge 200KB -or @($bytes | Where-Object { $_ -gt 127 }).Count) { throw 'Installer must be ASCII and less than 200 KB.' }
$tokens = $null
$parseErrors = $null
$installerAst = [Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
if ($TargetSecurityGroupId -ne [guid]::Empty) {
    $mode = @($installerAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'TargetingMode' })
    if ($mode.Count -ne 1 -or $mode[0].DefaultValue.Extent.Text -ne "'SingleDevice'") {
        throw 'Expected the installer SingleDevice default before preparing group-targeted content.'
    }
    # Intune platform scripts have no argument field; change only the uploaded default.
    $extent = $mode[0].DefaultValue.Extent
    $source = [IO.File]::ReadAllText($installerPath)
    $source = $source.Remove($extent.StartOffset, $extent.EndOffset - $extent.StartOffset).Insert($extent.StartOffset, "'SecurityGroup'")
    $bytes = [Text.Encoding]::ASCII.GetBytes($source)
}
if ($bytes.Length -ge 200KB) { throw 'Prepared Intune installer must be less than 200 KB.' }
$content = [Convert]::ToBase64String($bytes)
if ($TargetSecurityGroupId -eq [guid]::Empty) {
    $groupName = 'Contoso-AMA-CONTOSO-PC' # Replace with your dedicated pilot group name.
    $marker = 'ContosoDeviceMonitoring; single-device AMA client deployment; managedDevice=55555555-5555-5555-5555-555555555555' # Keep this ID aligned with $managedId.
    $groups = @(Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$groupName'")
    if ($groups.Count -gt 1) { throw 'Ambiguous project group name.' }
    if ($groups.Count) {
        $group = $groups[0]
        if ($group.description -ne $marker -or -not $group.securityEnabled -or $group.mailEnabled -or @($group.groupTypes).Count) { throw 'Existing group is not the expected static project security group.' }
    }
    else {
        if (-not $PSCmdlet.ShouldProcess($groupName, 'Create dedicated single-device security group')) { return }
        $group = Send-GraphJson POST 'https://graph.microsoft.com/v1.0/groups' @{
            displayName = $groupName; description = $marker; securityEnabled = $true
            mailEnabled = $false; mailNickname = 'ContosoAMAPilotPC'; groupTypes = @() # Replace with a suitable group alias.
        }
    }
    $membersUri = "https://graph.microsoft.com/v1.0/groups/$($group.id)/members"
    $members = @(Get-GraphCollection -Uri $membersUri)
    if (@($members | Where-Object { $_.id -ne $directoryId }).Count) { throw 'Project group contains unexpected members. Assignment refused.' }
    if (-not $members.Count) {
        if (-not $PSCmdlet.ShouldProcess($group.id, 'Add the verified Intune device directory object')) { return }
        Send-GraphJson POST ($membersUri + '/$ref') @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$directoryId" } | Out-Null
    }
    $members = @(Get-GraphCollection -Uri $membersUri)
    if ($members.Count -ne 1 -or $members[0].id -ne $directoryId) { throw 'Single-device membership read-back failed; retry after propagation.' }
}

$scriptsUri = 'https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts'
$scriptName = 'Contoso - Install AMA - CONTOSO-PC' # Replace with your pilot deployment name.
if ($TargetSecurityGroupId -ne [guid]::Empty) { $scriptName = "Contoso - Install AMA - Group $TargetSecurityGroupId" }
$existing = @(Get-GraphCollection -Uri $scriptsUri | Where-Object { $_.displayName -eq $scriptName })
if ($existing.Count -gt 1) { throw 'Ambiguous project script name.' }
if ($existing.Count) {
    $script = $existing[0]
}
else {
    if (-not $PSCmdlet.ShouldProcess($scriptName, 'Upload silent installer (SYSTEM, 64-bit, unsigned script)')) { return }
    $script = Send-GraphJson POST $scriptsUri @{
        '@odata.type' = '#microsoft.graph.deviceManagementScript'
        displayName = $scriptName; description = $marker; scriptContent = $content
        runAsAccount = 'system'; runAs32Bit = $false; enforceSignatureCheck = $false
        fileName = 'Install-AzureMonitorAgent.ps1'; roleScopeTagIds = @('0')
    }
}
$scriptUri = "$scriptsUri/$($script.id)"
$script = Invoke-MgGraphRequest -Method GET -Uri $scriptUri -OutputType PSObject
if ($script.description -ne $marker -or $script.scriptContent -ne $content -or $script.runAsAccount -ne 'system' -or $script.runAs32Bit -or $script.enforceSignatureCheck) {
    throw 'Uploaded script content or execution settings differ. No assignment made.'
}
$assignments = @(Get-GraphCollection -Uri "$scriptUri/assignments")
foreach ($assignment in $assignments) {
    if ($assignment.target.'@odata.type' -ne '#microsoft.graph.groupAssignmentTarget' -or $assignment.target.groupId -ne $group.id -or $assignment.target.deviceAndAppManagementAssignmentFilterType -notin @($null, 'none')) {
        throw 'Unexpected existing assignment. Refusing to overwrite it.'
    }
}
if (-not $assignments.Count) {
    if ($TargetSecurityGroupId -ne [guid]::Empty) { $null = Get-ValidatedTargetGroup -GroupId $TargetSecurityGroupId }
    if (-not $PSCmdlet.ShouldProcess($groupName, 'Assign AMA installer to the verified device security group')) { return }
    Send-GraphJson POST "$scriptUri/assign" @{
        deviceManagementScriptAssignments = @(@{
            '@odata.type' = '#microsoft.graph.deviceManagementScriptAssignment'
            target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $group.id }
        })
    } | Out-Null
}
$assignments = @(Get-GraphCollection -Uri "$scriptUri/assignments")
if ($assignments.Count -ne 1 -or $assignments[0].target.groupId -ne $group.id -or
    $assignments[0].target.'@odata.type' -ne '#microsoft.graph.groupAssignmentTarget' -or
    $assignments[0].target.deviceAndAppManagementAssignmentFilterType -notin @($null, 'none')) { throw 'Assignment read-back failed.' }
$sha256 = [Security.Cryptography.SHA256]::Create()
try { $installerHash = [BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '') }
finally { $sha256.Dispose() }
[pscustomobject]@{
    CheckedAtUtc = [DateTime]::UtcNow.ToString('o')
    GroupId = $group.id
    ScriptId = $script.id
    ManagedDeviceId = if ($TargetSecurityGroupId -eq [guid]::Empty) { $managedId } else { $null }
    DirectoryObjectId = if ($TargetSecurityGroupId -eq [guid]::Empty) { $directoryId } else { $null }
    TargetingMode = if ($TargetSecurityGroupId -ne [guid]::Empty) { 'SecurityGroup' } else { 'SingleDevice' }
    InstallerSHA256 = $installerHash
    AssignmentVerified = $true
    InstallationVerified = $false
}