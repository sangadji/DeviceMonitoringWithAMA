[CmdletBinding()]
param(
    [switch]$DeploymentAccess
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Authentication
$tenantId = '11111111-1111-1111-1111-111111111111' # Replace with your Entra tenant ID.
$expectedAccount = 'admin@contoso.example' # Replace with your authorized administrator UPN.

$scopes = @('DeviceManagementManagedDevices.Read.All', 'Device.Read.All')
if ($DeploymentAccess) {
    $scopes += @('DeviceManagementScripts.ReadWrite.All', 'Group.ReadWrite.All')
}
Connect-MgGraph -TenantId $tenantId -Scopes $scopes -UseDeviceCode -ContextScope CurrentUser -NoWelcome
$context = Get-MgContext
if ($context.TenantId -ne $tenantId -or $context.Account -ine $expectedAccount) {
    Disconnect-MgGraph | Out-Null
    throw 'Unexpected Graph account or tenant. No device records were requested.'
}

$managedDevices = @()
$nextLink = 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$select=id,deviceName,azureADDeviceId,operatingSystem,osVersion,lastSyncDateTime,managementAgent,userPrincipalName'
while ($nextLink) {
    $page = Invoke-MgGraphRequest -Method GET -Uri $nextLink -OutputType PSObject
    $managedDevices += @($page.value)
    $nextLink = $page.'@odata.nextLink'
}

$joinedDeviceId = '33333333-3333-3333-3333-333333333333' # Replace with the local Entra joined device ID.
$registeredDeviceId = '44444444-4444-4444-4444-444444444444' # Replace with the Entra device ID mapped by Intune; it may equal the joined ID.
$directoryDevices = @()
foreach ($deviceId in @($joinedDeviceId, $registeredDeviceId)) {
    $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=deviceId eq '$deviceId'&`$select=id,deviceId,displayName,trustType,accountEnabled,isManaged,isCompliant"
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
    $directoryDevices += @($page.value)
}

[pscustomobject]@{
    CheckedAtUtc = [DateTime]::UtcNow.ToString('o')
    Account = $context.Account
    TenantId = $context.TenantId
    ManagedDeviceCount = $managedDevices.Count
    MatchingManagedDevices = @($managedDevices | Where-Object {
        $_.azureADDeviceId -in @($joinedDeviceId, $registeredDeviceId) -or $_.deviceName -eq 'CONTOSO-PC' # Replace with the target computer name.
    })
    DirectoryDevices = $directoryDevices
} | ConvertTo-Json -Depth 8