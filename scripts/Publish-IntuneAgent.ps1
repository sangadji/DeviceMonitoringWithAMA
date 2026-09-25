[CmdletBinding(SupportsShouldProcess)]
param()

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

$managedId = '55555555-5555-5555-5555-555555555555' # Replace with the Intune managed-device ID.
$directoryId = '66666666-6666-6666-6666-666666666666' # Replace with the mapped Entra directory object ID, not the device ID.
$registeredId = '44444444-4444-4444-4444-444444444444' # Replace with the Entra device ID mapped by Intune.
$managed = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$managedId" -OutputType PSObject
if ($managed.deviceName -ine 'CONTOSO-PC' -or $managed.azureADDeviceId -ne $registeredId -or $managed.operatingSystem -ne 'Windows') { # Replace with the target computer name.
    throw 'Intune device identity changed. Review inventory before deployment.'
}
$directory = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/devices/$directoryId" -OutputType PSObject
if ($directory.deviceId -ne $registeredId -or -not $directory.accountEnabled) { throw 'Unexpected or disabled directory device.' }
$installerPath = Join-Path $PSScriptRoot 'Install-AzureMonitorAgent.ps1'
$bytes = [IO.File]::ReadAllBytes($installerPath)
if ($bytes.Length -ge 200KB -or @($bytes | Where-Object { $_ -gt 127 }).Count) { throw 'Installer must be ASCII and less than 200 KB.' }
$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$content = [Convert]::ToBase64String($bytes)
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

$scriptsUri = 'https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts'
$scriptName = 'Contoso - Install AMA - CONTOSO-PC' # Replace with your pilot deployment name.
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
    if (-not $PSCmdlet.ShouldProcess($groupName, 'Assign AMA installer to the verified single-device group')) { return }
    Send-GraphJson POST "$scriptUri/assign" @{
        deviceManagementScriptAssignments = @(@{
            '@odata.type' = '#microsoft.graph.deviceManagementScriptAssignment'
            target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $group.id }
        })
    } | Out-Null
}
$assignments = @(Get-GraphCollection -Uri "$scriptUri/assignments")
if ($assignments.Count -ne 1 -or $assignments[0].target.groupId -ne $group.id -or $assignments[0].target.'@odata.type' -ne '#microsoft.graph.groupAssignmentTarget') { throw 'Assignment read-back failed.' }
[pscustomobject]@{
    CheckedAtUtc = [DateTime]::UtcNow.ToString('o')
    GroupId = $group.id
    ScriptId = $script.id
    ManagedDeviceId = $managedId
    DirectoryObjectId = $directoryId
    InstallerSHA256 = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
    AssignmentVerified = $true
    InstallationVerified = $false
}