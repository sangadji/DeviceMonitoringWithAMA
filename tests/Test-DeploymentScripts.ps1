[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($script in Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1') {
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
}
$installerPath = Join-Path $root 'scripts\Install-AzureMonitorAgent.ps1'
$source = [IO.File]::ReadAllText($installerPath)
if ([Text.Encoding]::UTF8.GetByteCount($source) -ge 200KB -or $source -match '[^\x00-\x7F]') { throw 'Intune script must be ASCII and less than 200 KB.' }
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$parseErrors)
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($function in $functions) { . ([scriptblock]::Create($function.Extent.Text)) }

function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Expected rejection did not occur.' }
}

$joinStatus = @(
    'AzureAdJoined : YES'
    'DeviceAuthStatus : SUCCESS'
    'TenantId : 11111111-1111-1111-1111-111111111111' # Synthetic tenant matching the installer guard.
    'DeviceId : 33333333-3333-3333-3333-333333333333' # Synthetic device matching the installer guard.
) -join [Environment]::NewLine
Assert-TargetDevice $joinStatus 'CONTOSO-PC' 'S-1-5-18' $true # Match the installer computer-name guard.
Assert-Rejected { Assert-TargetDevice $joinStatus 'OTHER-PC' 'S-1-5-18' $true }
Assert-Rejected { Assert-TargetDevice $joinStatus 'CONTOSO-PC' 'S-1-5-32-544' $true } # Synthetic device fixture.
Assert-Rejected { Assert-TargetDevice $joinStatus 'CONTOSO-PC' 'S-1-5-18' $false } # Synthetic device fixture.
Assert-Rejected { Assert-TargetDevice ($joinStatus.Replace('YES', 'NO')) 'CONTOSO-PC' 'S-1-5-18' $true } # Synthetic device fixture.
Assert-Rejected { Assert-TargetDevice ($joinStatus.Replace('SUCCESS', 'FAILED')) 'CONTOSO-PC' 'S-1-5-18' $true } # Synthetic device fixture.
Assert-Rejected { Assert-TargetDevice ($joinStatus.Replace('11111111', '00000000')) 'CONTOSO-PC' 'S-1-5-18' $true } # Mutate the synthetic tenant ID to test rejection.
Assert-Rejected { Assert-TargetDevice ($joinStatus.Replace('33333333', '00000000')) 'CONTOSO-PC' 'S-1-5-18' $true } # Mutate the synthetic device ID to test rejection.
Assert-InstallerExitCode 0
Assert-InstallerExitCode 3010 | Out-Null
Assert-Rejected { Assert-InstallerExitCode 1603 }
Assert-Rejected { Assert-InstallerExitCode 1618 }
Assert-Rejected { Assert-InstallerExitCode 1641 }
'PASS: PowerShell syntax, Intune size/encoding, target guards, and installer exit codes. No installation performed.'

$controlPath = Join-Path $root 'scripts\Set-MonitoringCollection.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($controlPath, [ref]$tokens, [ref]$parseErrors)
foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
$template = Get-Content (Join-Path $root 'infra\azuredeploy.json') -Raw | ConvertFrom-Json
if ($template.parameters.samplingSeconds.allowedValues -or $template.parameters.samplingSeconds.minValue -ne 1) { throw 'Template still restricts custom intervals.' }
$ruleFixture = $template.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }
$original = $ruleFixture | ConvertTo-Json -Depth 100
foreach ($interval in @(1, 7, 10, 37, 60, 300, 600)) {
    $body = Get-MonitoringRuleBody -Rule $ruleFixture -Interval $interval
    if ($body.properties.dataSources.performanceCounters[0].samplingFrequencyInSeconds -ne $interval) { throw 'Interval not updated.' }
    if (($body.properties.destinations | ConvertTo-Json -Depth 20) -ne ($ruleFixture.properties.destinations | ConvertTo-Json -Depth 20)) { throw 'Destination changed.' }
    if ($body.properties.dataSources.performanceCounters[0].counterSpecifiers.Count -ne 18) { throw 'Counters lost.' }
}
if (($ruleFixture | ConvertTo-Json -Depth 100) -ne $original) { throw 'Input DCR mutated.' }
foreach ($invalid in @('0', '-1', '1.5', 'abc', '2147483648')) {
    Assert-Rejected { & $controlPath -Action SetInterval -SamplingSeconds $invalid }
}

$testRuleId = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-contoso-device-monitoring-idc/providers/Microsoft.Insights/dataCollectionRules/dcr-contoso-windows-performance' # Synthetic subscription matching the collection guard.
$testAssociationRoot = '/providers/Microsoft.Insights/monitoredObjects/11111111-1111-1111-1111-111111111111/providers/Microsoft.Insights/dataCollectionRuleAssociations' # Synthetic tenant matching the collection guard.
$script:testAssociations = @(
    [pscustomobject]@{ id = "$testAssociationRoot/project"; name = 'project'; properties = @{ dataCollectionRuleId = $testRuleId } },
    [pscustomobject]@{ id = "$testAssociationRoot/other"; name = 'other'; properties = @{ dataCollectionRuleId = '/another-rule' } }
)
$script:testWrites = 0
$ruleFixture.properties | Add-Member -NotePropertyName provisioningState -NotePropertyValue 'Succeeded' -Force
$ruleFixture.properties.dataSources.performanceCounters[0].samplingFrequencyInSeconds = 10
function Invoke-MonitoringAzureJson {
    param([string[]]$Arguments, $Body)
    if ($Arguments[0] -eq 'account') {
        return [pscustomobject]@{ tenantId = '11111111-1111-1111-1111-111111111111'; id = '22222222-2222-2222-2222-222222222222'; user = @{ name = 'admin@contoso.example' } } # Synthetic account matching the collection guards; Azure calls stay mocked.
    }
    if ($Arguments[2] -eq 'delete') {
        if ($Arguments[4] -notlike "*${testAssociationRoot}/project?*") { throw 'Attempted deletion of unrelated association.' }
        $script:testWrites++
        $script:testAssociations = @($script:testAssociations | Where-Object { $_.name -ne 'project' })
        return
    }
    if ($Arguments[2] -eq 'put') {
        if ($Arguments[4] -notlike "*${testAssociationRoot}/contoso-windows-performance?*" -or $Body.properties.dataCollectionRuleId -ne $testRuleId) { throw 'Unexpected association write.' }
        $script:testWrites++
        $script:testAssociations += [pscustomobject]@{ id = "$testAssociationRoot/contoso-windows-performance"; name = 'contoso-windows-performance'; properties = @{ dataCollectionRuleId = $testRuleId } }
        return
    }
    if ($Arguments[2] -ne 'get') { throw 'Unexpected write during control test.' }
    if ($Arguments[4] -like '*dataCollectionRuleAssociations?*') { return [pscustomobject]@{ value = $script:testAssociations } }
    return $ruleFixture
}
$status = Invoke-MonitoringCollection -Action Status
if (-not $status.ConfigurationAssociated -or $status.OtherAssociationCount -ne 1 -or $script:testWrites) { throw 'Incorrect status.' }
Invoke-MonitoringCollection -Action Stop -WhatIf | Out-Null
if ($script:testWrites) { throw 'WhatIf performed a write.' }
$status = Invoke-MonitoringCollection -Action Stop -Confirm:$false
if ($status.ConfigurationAssociated -or $status.OtherAssociationCount -ne 1 -or $script:testWrites -ne 1) { throw 'Stop did not preserve unrelated associations.' }
Invoke-MonitoringCollection -Action Stop -Confirm:$false | Out-Null
if ($script:testWrites -ne 1) { throw 'Stop is not idempotent.' }
'PASS: custom intervals, payload preservation, invalid inputs, status, WhatIf, scoped stop, and repeated stop. Azure calls mocked.'
Assert-Rejected { Invoke-MonitoringCollection -Action Start }
$ruleFixture.properties.dataSources.performanceCounters[0].samplingFrequencyInSeconds = 1
Assert-Rejected { Invoke-MonitoringCollection -Action Start -AcknowledgeTenantScope }
$ruleFixture.properties.dataSources.performanceCounters[0].samplingFrequencyInSeconds = 10
Invoke-MonitoringCollection -Action Start -AcknowledgeTenantScope -WhatIf | Out-Null
if ($script:testWrites -ne 1) { throw 'Start WhatIf performed a write.' }
$script:testAssociations += [pscustomobject]@{ name = 'contoso-windows-performance'; properties = @{ dataCollectionRuleId = '/another-rule' } }
Assert-Rejected { Invoke-MonitoringCollection -Action Start -AcknowledgeTenantScope }
$script:testAssociations = @($script:testAssociations | Where-Object { $_.name -ne 'contoso-windows-performance' })
$status = Invoke-MonitoringCollection -Action Start -AcknowledgeTenantScope -Confirm:$false
if (-not $status.ConfigurationAssociated -or $status.OtherAssociationCount -ne 1 -or $script:testWrites -ne 2) { throw 'Start failed or changed other associations.' }
Invoke-MonitoringCollection -Action Start -AcknowledgeTenantScope -Confirm:$false | Out-Null
if ($script:testWrites -ne 2) { throw 'Start is not idempotent.' }
'PASS: Start scope acknowledgement, one-second guard, collision refusal, WhatIf, and idempotency. Azure calls mocked.'