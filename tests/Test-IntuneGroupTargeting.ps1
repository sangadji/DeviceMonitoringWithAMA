[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$publisherPath = Join-Path $root 'scripts\Publish-IntuneAgent.ps1'
$installerPath = Join-Path $root 'scripts\Install-AzureMonitorAgent.ps1'
$installerHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
$groupTestState = @{}
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$parseErrors)
foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}

function Assert-GroupRejected {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected rejection containing: $Message"
}

$joinStatus = @(
    'AzureAdJoined : YES'
    'DeviceAuthStatus : SUCCESS'
    'TenantId : 11111111-1111-1111-1111-111111111111'
    'DeviceId : 33333333-3333-3333-3333-333333333333'
) -join [Environment]::NewLine
Assert-TargetDevice $joinStatus 'CONTOSO-PC' 'S-1-5-18' $true
Assert-GroupRejected { Assert-TargetDevice $joinStatus 'SECOND-PC' 'S-1-5-18' $true } 'Unexpected computer name'
foreach ($name in @('CONTOSO-PC', 'SECOND-PC')) {
    $status = if ($name -eq 'SECOND-PC') { $joinStatus.Replace('33333333', '88888888') } else { $joinStatus }
    Assert-TargetDevice $status $name 'S-1-5-18' $true -TargetingMode SecurityGroup
}
Assert-GroupRejected { Assert-TargetDevice $joinStatus 'SECOND-PC' 'S-1-5-32-544' $true -TargetingMode SecurityGroup } 'SYSTEM'
Assert-GroupRejected { Assert-TargetDevice $joinStatus 'SECOND-PC' 'S-1-5-18' $false -TargetingMode SecurityGroup } '64-bit'
foreach ($invalidStatus in @(
    $joinStatus.Replace('YES', 'NO'),
    $joinStatus.Replace('SUCCESS', 'FAILED'),
    $joinStatus.Replace('11111111', '00000000'),
    $joinStatus.Replace('33333333-3333-3333-3333-333333333333', 'not-a-guid'),
    $joinStatus.Replace('33333333-3333-3333-3333-333333333333', '00000000-0000-0000-0000-000000000000'),
    ($joinStatus -replace '(?m)^DeviceId.*$', '')
)) {
    Assert-GroupRejected { Assert-TargetDevice $invalidStatus 'SECOND-PC' 'S-1-5-18' $true -TargetingMode SecurityGroup } 'Entra prerequisite failed'
}
'PASS: group installer accepts two devices while retaining tenant, join, identity, SYSTEM, and x64 checks; single-device default preserved.'

function Reset-GroupFixture {
    param([switch]$SingleDevice)

    $groupTestState.groupId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $groupTestState.groupFixture = [pscustomobject]@{
        id = $groupTestState.groupId; displayName = 'AMA-Pilot-Devices'
        securityEnabled = $true; mailEnabled = $false; groupTypes = @()
        description = 'ContosoDeviceMonitoring; single-device AMA client deployment; managedDevice=55555555-5555-5555-5555-555555555555'
    }
    $groupTestState.deviceFixtures = @(
        [pscustomobject]@{ id = '66666666-6666-6666-6666-666666666666'; deviceId = '44444444-4444-4444-4444-444444444444'; accountEnabled = $true; operatingSystem = 'Windows' },
        [pscustomobject]@{ id = '99999999-9999-9999-9999-999999999999'; deviceId = '88888888-8888-8888-8888-888888888888'; accountEnabled = $true; operatingSystem = 'Windows' }
    )
    $groupTestState.memberFixtures = @($groupTestState.deviceFixtures | ForEach-Object {
        [pscustomobject]@{ id = $_.id; '@odata.type' = '#microsoft.graph.device' }
    })
    $groupTestState.managedFixtures = @($groupTestState.deviceFixtures | ForEach-Object {
        [pscustomobject]@{ azureADDeviceId = $_.deviceId; operatingSystem = 'Windows' }
    })
    if ($SingleDevice) { $groupTestState.memberFixtures = @($groupTestState.memberFixtures[0]) }
    $groupTestState.publishedScript = $null
    $groupTestState.assignmentFixtures = @()
    $groupTestState.graphWrites = 0
    $groupTestState.memberPages = 0
    $groupTestState.managedPages = 0
    $groupTestState.graphAccount = 'admin@contoso.example'
    $groupTestState.graphTenant = '11111111-1111-1111-1111-111111111111'
    $groupTestState.graphScopes = @('DeviceManagementScripts.ReadWrite.All', 'Group.ReadWrite.All', 'Device.Read.All', 'DeviceManagementManagedDevices.Read.All')
    $groupTestState.failWrites = $false
}

function Import-Module {
    param([string]$Name)
    if ($Name -ne 'Microsoft.Graph.Authentication') { throw "Unexpected module import: $Name" }
}

function Get-MgContext {
    [pscustomobject]@{ TenantId = $groupTestState.graphTenant; Account = $groupTestState.graphAccount; Scopes = $groupTestState.graphScopes }
}

function Invoke-MgGraphRequest {
    param([string]$Method, [string]$Uri, [string]$Body, [string]$ContentType, [string]$OutputType)

    $groupsUri = 'https://graph.microsoft.com/v1.0/groups'
    $managedUri = 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices'
    $scriptsUri = 'https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts'
    if ($Method -eq 'GET') {
        if ($Uri -eq "$groupsUri/$($groupTestState.groupId)" -or $Uri.StartsWith($groupsUri + '?')) {
            if ($Uri.StartsWith($groupsUri + '?')) { return @{ value = @($groupTestState.groupFixture) } }
            return $groupTestState.groupFixture
        }
        if ($Uri -eq "$groupsUri/$($groupTestState.groupId)/members") {
            $groupTestState.memberPages++
            if (-not $groupTestState.memberFixtures.Count) { return @{ value = @() } }
            $page = @{ value = @($groupTestState.memberFixtures[0]) }
            if ($groupTestState.memberFixtures.Count -gt 1) { $page.'@odata.nextLink' = "$groupsUri/$($groupTestState.groupId)/members?next=2" }
            return $page
        }
        if ($Uri -eq "$groupsUri/$($groupTestState.groupId)/members?next=2") {
            $groupTestState.memberPages++
            return @{ value = @($groupTestState.memberFixtures | Select-Object -Skip 1) }
        }
        if ($Uri.StartsWith($managedUri + '?')) {
            $groupTestState.managedPages++
            if ($Uri -eq "$managedUri`?next=2") { return @{ value = @($groupTestState.managedFixtures | Select-Object -Skip 1) } }
            if (-not $groupTestState.managedFixtures.Count) { return @{ value = @() } }
            $page = @{ value = @($groupTestState.managedFixtures[0]) }
            if ($groupTestState.managedFixtures.Count -gt 1) { $page.'@odata.nextLink' = "$managedUri`?next=2" }
            return $page
        }
        if ($Uri -eq "$managedUri/55555555-5555-5555-5555-555555555555") {
            return @{ deviceName = 'CONTOSO-PC'; azureADDeviceId = $groupTestState.deviceFixtures[0].deviceId; operatingSystem = 'Windows' }
        }
        foreach ($device in $groupTestState.deviceFixtures) {
            if ($Uri -eq "https://graph.microsoft.com/v1.0/devices/$($device.id)") { return $device }
        }
        if ($Uri -eq $scriptsUri) {
            return @{ value = @(if ($null -ne $groupTestState.publishedScript) { $groupTestState.publishedScript }) }
        }
        if ($Uri -eq "$scriptsUri/test-script") { return $groupTestState.publishedScript }
        if ($Uri -eq "$scriptsUri/test-script/assignments") { return @{ value = $groupTestState.assignmentFixtures } }
    }
    if ($Method -eq 'POST') {
        if ($groupTestState.failWrites) { throw 'Simulated Graph write failure.' }
        $payload = $Body | ConvertFrom-Json
        if ($Uri -eq $scriptsUri) {
            $groupTestState.graphWrites++
            $payload | Add-Member -NotePropertyName id -NotePropertyValue 'test-script'
            $groupTestState.publishedScript = $payload
            return $payload
        }
        if ($Uri -eq "$scriptsUri/test-script/assign") {
            $groupTestState.graphWrites++
            $groupTestState.assignmentFixtures = @($payload.deviceManagementScriptAssignments)
            return
        }
    }
    throw "Unexpected Graph request (group mutation is forbidden): $Method $Uri"
}

Reset-GroupFixture
& $publisherPath -TargetSecurityGroupId $groupTestState.groupId -WhatIf | Out-Null
if ($groupTestState.graphWrites) { throw 'Group targeting WhatIf performed a write.' }
$result = & $publisherPath -TargetSecurityGroupId $groupTestState.groupId -Confirm:$false
if (-not $result.AssignmentVerified -or $result.InstallationVerified -or $result.TargetingMode -ne 'SecurityGroup' -or
    $result.GroupId -ne $groupTestState.groupId -or $groupTestState.graphWrites -ne 2 -or
    $groupTestState.assignmentFixtures[0].target.groupId -ne $groupTestState.groupId) { throw 'Two-device group publishing failed.' }
if ($groupTestState.memberPages -lt 4 -or $groupTestState.managedPages -lt 4) { throw 'Group or managed-device pagination was not exercised.' }
$uploadedBytes = [Convert]::FromBase64String($groupTestState.publishedScript.scriptContent)
$uploadedSource = [Text.Encoding]::ASCII.GetString($uploadedBytes)
$uploadedAst = [Management.Automation.Language.Parser]::ParseInput($uploadedSource, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -or $uploadedBytes.Length -ge 200KB -or $uploadedSource -match '[^\x00-\x7F]') { throw 'Invalid uploaded installer.' }
$mode = @($uploadedAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'TargetingMode' })
if ($mode.Count -ne 1 -or $mode[0].DefaultValue.Extent.Text -ne "'SecurityGroup'") { throw 'Uploaded installer is not group-targeted.' }
$originalSource = [IO.File]::ReadAllText($installerPath)
$originalMode = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'TargetingMode' })[0]
$extent = $originalMode.DefaultValue.Extent
$expectedSource = $originalSource.Remove($extent.StartOffset, $extent.EndOffset - $extent.StartOffset).Insert($extent.StartOffset, "'SecurityGroup'")
if ($uploadedSource -cne $expectedSource) { throw 'Publisher changed more than the uploaded targeting default.' }
$sha256 = [Security.Cryptography.SHA256]::Create()
try { $uploadedHash = [BitConverter]::ToString($sha256.ComputeHash($uploadedBytes)).Replace('-', '') }
finally { $sha256.Dispose() }
if ($result.InstallerSHA256 -ne $uploadedHash -or (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash -ne $installerHash) {
    throw 'Uploaded hash is wrong or the local installer was modified.'
}
& $publisherPath -TargetSecurityGroupId $groupTestState.groupId -Confirm:$false | Out-Null
if ($groupTestState.graphWrites -ne 2) { throw 'Repeated group publishing is not idempotent.' }
$groupTestState.assignmentFixtures = @()
& $publisherPath -TargetSecurityGroupId $groupTestState.groupId -WhatIf | Out-Null
if ($groupTestState.graphWrites -ne 2 -or $groupTestState.assignmentFixtures.Count) { throw 'Assignment WhatIf performed a write.' }
& $publisherPath -TargetSecurityGroupId $groupTestState.groupId -Confirm:$false | Out-Null
if ($groupTestState.graphWrites -ne 3 -or $groupTestState.assignmentFixtures.Count -ne 1) { throw 'Existing unassigned script could not be assigned.' }
'PASS: two-device group upload and assignment, pagination, uploaded content/hash, unchanged local file, WhatIf, and idempotency. Graph calls mocked.'

foreach ($scenario in @('empty', 'not-security', 'mail', 'dynamic', 'user', 'nested', 'disabled', 'non-windows', 'unmanaged', 'invalid-id', 'wrong-account', 'wrong-tenant', 'missing-scope')) {
    Reset-GroupFixture
    $message = 'Target'
    switch ($scenario) {
        'empty' { $groupTestState.memberFixtures = @() }
        'not-security' { $groupTestState.groupFixture.securityEnabled = $false }
        'mail' { $groupTestState.groupFixture.mailEnabled = $true }
        'dynamic' { $groupTestState.groupFixture.groupTypes = @('DynamicMembership') }
        'user' { $groupTestState.memberFixtures[0].'@odata.type' = '#microsoft.graph.user' }
        'nested' { $groupTestState.memberFixtures[0].'@odata.type' = '#microsoft.graph.group' }
        'disabled' { $groupTestState.deviceFixtures[0].accountEnabled = $false }
        'non-windows' { $groupTestState.deviceFixtures[0].operatingSystem = 'Android' }
        'unmanaged' { $groupTestState.managedFixtures = @($groupTestState.managedFixtures[1]) }
        'invalid-id' { $groupTestState.deviceFixtures[0].deviceId = 'not-a-guid' }
        'wrong-account' { $groupTestState.graphAccount = 'other@contoso.example'; $message = 'account first' }
        'wrong-tenant' { $groupTestState.graphTenant = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; $message = 'account first' }
        'missing-scope' { $groupTestState.graphScopes = @(); $message = 'Missing delegated permission' }
    }
    Assert-GroupRejected { & $publisherPath -TargetSecurityGroupId $groupTestState.groupId -Confirm:$false } $message
    if ($groupTestState.graphWrites) { throw "Invalid target performed a write: $scenario" }
}
Reset-GroupFixture
Assert-GroupRejected { & $publisherPath -TargetSecurityGroupId 'not-a-guid' } 'TargetSecurityGroupId'
Assert-GroupRejected { & $publisherPath -TargetSecurityGroupId ([guid]::Empty) } 'TargetSecurityGroupId'
$groupTestState.failWrites = $true
Assert-GroupRejected { & $publisherPath -TargetSecurityGroupId $groupTestState.groupId -Confirm:$false } 'Simulated Graph write failure'

Reset-GroupFixture
& $publisherPath -TargetSecurityGroupId $groupTestState.groupId -Confirm:$false | Out-Null
$groupTestState.assignmentFixtures[0].target.groupId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
Assert-GroupRejected { & $publisherPath -TargetSecurityGroupId $groupTestState.groupId -Confirm:$false } 'Unexpected existing assignment'
if ($groupTestState.graphWrites -ne 2) { throw 'Conflicting assignment was overwritten.' }
$groupTestState.assignmentFixtures[0].target.groupId = $groupTestState.groupId
$groupTestState.assignmentFixtures[0].target | Add-Member -NotePropertyName deviceAndAppManagementAssignmentFilterType -NotePropertyValue 'include'
Assert-GroupRejected { & $publisherPath -TargetSecurityGroupId $groupTestState.groupId -Confirm:$false } 'Unexpected existing assignment'
$groupTestState.publishedScript.scriptContent = 'changed'
Assert-GroupRejected { & $publisherPath -TargetSecurityGroupId $groupTestState.groupId -Confirm:$false } 'Uploaded script content'
'PASS: invalid groups/members, authentication, missing permissions, invalid input, Graph failures, and assignment/content conflicts fail explicitly. No real Graph calls.'

Reset-GroupFixture -SingleDevice
$result = & $publisherPath -Confirm:$false
if ($result.TargetingMode -ne 'SingleDevice' -or -not $result.AssignmentVerified -or $result.InstallerSHA256 -ne $installerHash -or
    $groupTestState.publishedScript.scriptContent -ne [Convert]::ToBase64String([IO.File]::ReadAllBytes($installerPath))) { throw 'Default single-device publishing changed.' }
Reset-GroupFixture
Assert-GroupRejected { & $publisherPath -Confirm:$false } 'unexpected members'
if ($groupTestState.graphWrites) { throw 'Single-device targeting accepted a multi-device group.' }
'PASS: existing single-device publisher behavior preserved. No installation or cloud changes performed.'
