[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Status', 'SetInterval', 'Start', 'Stop')]
    [string]$Action = 'Status',

    [ValidatePattern('^[1-9][0-9]*$')]
    [ValidateScript({ [decimal]$_ -le [int]::MaxValue })]
    [string]$SamplingSeconds,

    [switch]$AcknowledgeTenantScope
)

$ErrorActionPreference = 'Stop'

function Invoke-MonitoringAzureJson {
    param([string[]]$Arguments, $Body)

    $command = Get-Command az.cmd -ErrorAction SilentlyContinue
    $azureCli = if ($command) { $command.Source } else { 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd' }
    if (-not (Test-Path -LiteralPath $azureCli)) { throw 'Install Azure CLI and sign in to the Contoso tenant first.' }
    $bodyPath = $null
    try {
        if ($null -ne $Body) {
            $bodyPath = [IO.Path]::GetTempFileName()
            [IO.File]::WriteAllText($bodyPath, ($Body | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
            $Arguments += @('--body', "@$bodyPath", '--headers', 'Content-Type=application/json')
        }
        $output = & $azureCli @Arguments --only-show-errors --output json
        if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed with exit code $LASTEXITCODE. No successful change is assumed." }
        if ($output) { ($output -join [Environment]::NewLine) | ConvertFrom-Json }
    }
    finally {
        if ($bodyPath) { Remove-Item -LiteralPath $bodyPath -Force }
    }
}

function Get-MonitoringRuleBody {
    param($Rule, [int]$Interval)

    $copy = $Rule | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $sources = @($copy.properties.dataSources.performanceCounters | Where-Object { $_.name -eq 'windowsPerformance' })
    if ($sources.Count -ne 1) { throw 'Expected exactly one windowsPerformance counter source.' }
    $sources[0].samplingFrequencyInSeconds = $Interval
    foreach ($readOnly in @('immutableId', 'provisioningState', 'endpoints', 'metadata')) {
        $copy.properties.PSObject.Properties.Remove($readOnly)
    }
    foreach ($destination in $copy.properties.destinations.logAnalytics) {
        $destination.PSObject.Properties.Remove('workspaceId')
    }
    $body = @{ location = $copy.location; kind = $copy.kind; properties = $copy.properties }
    foreach ($optional in @('tags', 'identity')) {
        if ($null -ne $copy.$optional) { $body[$optional] = $copy.$optional }
    }
    return $body
}

function Get-MonitoringAssociations {
    param([string]$Uri)

    while ($Uri) {
        $page = Invoke-MonitoringAzureJson -Arguments @('rest', '--method', 'get', '--url', $Uri)
        foreach ($association in $page.value) { $association }
        $Uri = $page.nextLink
        if ($Uri -and -not $Uri.StartsWith('https://management.azure.com/', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Unexpected association pagination host.'
        }
    }
}

function Invoke-MonitoringCollection {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Action = 'Status', [string]$SamplingSeconds, [switch]$AcknowledgeTenantScope)

    if ($Action -eq 'SetInterval' -and -not $SamplingSeconds) { throw 'SetInterval requires -SamplingSeconds.' }
    if ($Action -ne 'SetInterval' -and $SamplingSeconds) { throw '-SamplingSeconds is only valid with SetInterval.' }
    if ($Action -eq 'Start' -and -not $AcknowledgeTenantScope) { throw 'Start requires -AcknowledgeTenantScope: this DCR applies to all tenant AMA client installations.' }
    $tenantId = '11111111-1111-1111-1111-111111111111' # Replace with your Entra tenant ID.
    $subscriptionId = '22222222-2222-2222-2222-222222222222' # Replace with your Azure subscription ID.
    $account = Invoke-MonitoringAzureJson -Arguments @('account', 'show', '--subscription', $subscriptionId)
    if ($account.tenantId -ne $tenantId -or $account.id -ne $subscriptionId -or $account.user.name -ine 'admin@contoso.example') { # Replace with your authorized administrator UPN.
        throw 'Unexpected Azure account, tenant, or subscription. No changes made.'
    }
    $ruleId = "/subscriptions/$subscriptionId/resourceGroups/rg-contoso-device-monitoring-idc/providers/Microsoft.Insights/dataCollectionRules/dcr-contoso-windows-performance"
    $ruleUri = "https://management.azure.com${ruleId}?api-version=2023-03-11"
    $associationRoot = "https://management.azure.com/providers/Microsoft.Insights/monitoredObjects/$tenantId/providers/Microsoft.Insights/dataCollectionRuleAssociations"
    $associationListUri = "${associationRoot}?api-version=2023-03-11"
    $associations = @(Get-MonitoringAssociations -Uri $associationListUri)
    $projectAssociations = @($associations | Where-Object { $_.properties.dataCollectionRuleId -ieq $ruleId })

    if ($Action -eq 'Stop') {
        foreach ($association in $projectAssociations) {
            $expectedId = "$($associationRoot.Replace('https://management.azure.com', ''))/$($association.name)"
            if ($association.id -ine $expectedId -or $association.name -notmatch '^[a-zA-Z0-9_.-]+$') { throw 'Unexpected association identifier.' }
        }
        foreach ($association in $projectAssociations) {
            if ($PSCmdlet.ShouldProcess($association.id, 'Remove this project DCR association to stop its performance collection')) {
                $uri = "https://management.azure.com$($association.id)?api-version=2023-03-11"
                Invoke-MonitoringAzureJson -Arguments @('rest', '--method', 'delete', '--url', $uri) | Out-Null
            }
        }
    }

    $rule = Invoke-MonitoringAzureJson -Arguments @('rest', '--method', 'get', '--url', $ruleUri)
    if ($Action -eq 'Start') {
        if ($rule.properties.provisioningState -ne 'Succeeded') { throw 'DCR is not successfully provisioned.' }
        $source = @($rule.properties.dataSources.performanceCounters | Where-Object { $_.name -eq 'windowsPerformance' })
        if ($source.Count -ne 1) { throw 'Expected exactly one windowsPerformance source.' }
        if ($source[0].samplingFrequencyInSeconds -eq 1) { throw 'Set a baseline interval above one second before Start. One-second collection requires a separately bounded diagnostic.' }
        $associationName = 'contoso-windows-performance'
        $conflicts = @($associations | Where-Object { $_.name -eq $associationName -and $_.properties.dataCollectionRuleId -ine $ruleId })
        if ($conflicts.Count) { throw 'Project association name is already used by another DCR.' }
        if (-not $projectAssociations.Count -and $PSCmdlet.ShouldProcess($associationRoot, 'Associate the project DCR with all tenant AMA client installations')) {
            $uri = "${associationRoot}/${associationName}?api-version=2023-03-11"
            Invoke-MonitoringAzureJson -Arguments @('rest', '--method', 'put', '--url', $uri) -Body @{ properties = @{ dataCollectionRuleId = $ruleId } } | Out-Null
        }
    }
    if ($Action -eq 'SetInterval' -and $PSCmdlet.ShouldProcess($ruleId, "Set performance sampling to $SamplingSeconds seconds")) {
        $body = Get-MonitoringRuleBody -Rule $rule -Interval ([int]$SamplingSeconds)
        Invoke-MonitoringAzureJson -Arguments @('rest', '--method', 'put', '--url', $ruleUri) -Body $body | Out-Null
        $rule = Invoke-MonitoringAzureJson -Arguments @('rest', '--method', 'get', '--url', $ruleUri)
        $actual = @($rule.properties.dataSources.performanceCounters | Where-Object { $_.name -eq 'windowsPerformance' })
        if ($actual.Count -ne 1 -or $actual[0].samplingFrequencyInSeconds -ne [int]$SamplingSeconds -or $rule.properties.provisioningState -ne 'Succeeded') {
            throw 'DCR read-back did not confirm a successfully provisioned interval. Inspect Azure before retrying.'
        }
    }
    $associations = @(Get-MonitoringAssociations -Uri $associationListUri)
    $projectAssociations = @($associations | Where-Object { $_.properties.dataCollectionRuleId -ieq $ruleId })
    if ($Action -eq 'Stop' -and -not $WhatIfPreference -and $projectAssociations.Count) { throw 'Project associations remain; collection stop was not confirmed.' }
    if ($Action -eq 'Start' -and -not $WhatIfPreference -and -not $projectAssociations.Count) { throw 'Project association was not confirmed.' }
    [pscustomobject]@{
        CheckedAtUtc = [DateTime]::UtcNow.ToString('o')
        SamplingSeconds = @($rule.properties.dataSources.performanceCounters | Where-Object { $_.name -eq 'windowsPerformance' } | Select-Object -ExpandProperty samplingFrequencyInSeconds)
        ConfigurationAssociated = [bool]$projectAssociations.Count
        ProjectAssociationCount = $projectAssociations.Count
        OtherAssociationCount = @($associations | Where-Object { $_.properties.dataCollectionRuleId -ine $ruleId }).Count
        AgentRuntimeVerified = $false
        Note = 'Control-plane state only. Changes require agent configuration refresh; buffered data may still arrive. Other DCRs and agent heartbeat are not stopped.'
    }
}

Invoke-MonitoringCollection @PSBoundParameters