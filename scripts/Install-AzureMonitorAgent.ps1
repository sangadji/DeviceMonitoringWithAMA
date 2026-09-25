[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-TargetDevice {
    param([string]$JoinStatus, [string]$ComputerName, [string]$IdentitySid, [bool]$Is64Bit)

    if ($IdentitySid -ne 'S-1-5-18' -or -not $Is64Bit) {
        throw 'Intune must run this script as SYSTEM in 64-bit PowerShell.'
    }
    if ($ComputerName -ine 'CONTOSO-PC') { throw 'Unexpected computer name.' } # Replace with the target computer name; retain the guard.
    $required = @{
        AzureAdJoined = 'YES'
        DeviceAuthStatus = 'SUCCESS'
        TenantId = '11111111-1111-1111-1111-111111111111' # Replace with your Entra tenant ID.
        DeviceId = '33333333-3333-3333-3333-333333333333' # Replace with the device ID from dsregcmd /status.
    }
    foreach ($key in $required.Keys) {
        $pattern = '(?im)^\s*' + [regex]::Escape($key) + '\s*:\s*' + [regex]::Escape($required[$key]) + '\s*$'
        if ($JoinStatus -notmatch $pattern) { throw "Entra prerequisite failed: $key." }
    }
}

function Assert-InstallerExitCode {
    param([int]$ExitCode)

    if ($ExitCode -notin @(0, 3010)) { throw "Installer failed with exit code $ExitCode." }
    if ($ExitCode -eq 3010) { Write-Output 'Restart required by installer; no restart was initiated.' }
}

function Get-MicrosoftInstaller {
    param([string]$Uri, [string]$Destination)

    Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing -TimeoutSec 300
    $signature = Get-AuthenticodeSignature -FilePath $Destination
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw 'Installer does not have a valid Microsoft Corporation signature.'
    }
    Write-Output "Verified installer: $Destination"
    Write-Output "SHA256: $((Get-FileHash -Path $Destination -Algorithm SHA256).Hash)"
    Write-Output "Signer: $($signature.SignerCertificate.Subject)"
}

function Invoke-SilentInstaller {
    param([string]$FilePath, [string]$Arguments)

    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru
    if (-not $process.WaitForExit(600000)) { throw 'Installer exceeded ten minutes; inspect its log before retrying.' }
    $process.Refresh()
    Assert-InstallerExitCode -ExitCode $process.ExitCode
}

$transcriptStarted = $false
try {
    $joinStatus = (& "$env:windir\System32\dsregcmd.exe" /status | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read Entra join status.' }
    Assert-TargetDevice -JoinStatus $joinStatus -ComputerName $env:COMPUTERNAME -IdentitySid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -Is64Bit ([Environment]::Is64BitProcess)

    $logRoot = Join-Path $env:ProgramData 'ContosoDeviceMonitoring'
    $trustedSids = @('S-1-5-18', 'S-1-5-32-544')
    if (Test-Path -LiteralPath $logRoot) {
        $folder = Get-Item -LiteralPath $logRoot -Force
        if (-not $folder.PSIsContainer -or ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe staging directory.' }
        $existingAcl = Get-Acl -LiteralPath $logRoot
        if ($existingAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trustedSids) { throw 'Untrusted staging owner.' }
        foreach ($rule in $existingAcl.Access) {
            if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $trustedSids) {
                throw 'Staging directory allows access to an unexpected principal.'
            }
        }
    }
    else {
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($trustedSid in $trustedSids) {
            $sid = New-Object Security.Principal.SecurityIdentifier($trustedSid)
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        [IO.Directory]::CreateDirectory($logRoot, $acl) | Out-Null
    }
    $runRoot = Join-Path $logRoot ([Guid]::NewGuid().ToString())
    [IO.Directory]::CreateDirectory($runRoot) | Out-Null
    Start-Transcript -Path (Join-Path $runRoot 'install.log') -Force | Out-Null
    $transcriptStarted = $true
    Write-Output "Started UTC: $([DateTime]::UtcNow.ToString('o'))"

    $service = Get-Service -Name AzureMonitorAgent -ErrorAction SilentlyContinue
    if (-not $service) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $runtime = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
        if (-not $runtime -or $runtime.Installed -ne 1) {
            $redistPath = Join-Path $runRoot 'vc_redist.x64.exe'
            Get-MicrosoftInstaller -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -Destination $redistPath
            Invoke-SilentInstaller -FilePath $redistPath -Arguments ('/install /quiet /norestart /log "{0}"' -f (Join-Path $runRoot 'vcredist.log'))
        }
        $msiPath = Join-Path $runRoot 'AzureMonitorAgentClientSetup.msi'
        Get-MicrosoftInstaller -Uri 'https://go.microsoft.com/fwlink/?linkid=2192409' -Destination $msiPath
        Invoke-SilentInstaller -FilePath "$env:windir\System32\msiexec.exe" -Arguments ('/i "{0}" /qn /norestart /L*v "{1}"' -f $msiPath, (Join-Path $runRoot 'ama-msi.log'))
        $service = Get-Service -Name AzureMonitorAgent -ErrorAction Stop
    }
    if ($service.Status -ne 'Running') { Start-Service -Name AzureMonitorAgent }
    $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' |
        Where-Object { $_.DisplayName -like '*Azure Monitor Agent*' } |
        Select-Object DisplayName, DisplayVersion, PSChildName | Format-List
    Write-Output 'AzureMonitorAgent is running. Installation does not prove telemetry ingestion.'
    Get-ChildItem -LiteralPath $runRoot -File | Where-Object { $_.Extension -in @('.msi', '.exe') } | Remove-Item -Force
}
catch {
    Write-Output "FAILED: $($_.Exception.Message)"
    exit 1
}
finally {
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
}
exit 0