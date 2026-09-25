# Contoso Windows Device Monitoring Lab Runbook

For the focused deployment tutorial and KQL visualization walkthrough, start
with [Monitor Intune-Managed Windows Devices With AMA](README.md).
This runbook retains sanitized lab history. `CONTOSO-PC`, `admin@contoso.example`,
and repeated-digit GUIDs are fictional placeholders, not live deployment targets.
Inline code comments identify values to customize consistently across scripts,
tests, and queries. Public examples will not operate on the original environment.

## Historical Result: Intune Deployment And 10-Second Telemetry Verified

The narrative below records the initial deployment, not current cloud state.
The project DCR association was later removed on September 25, 2026 to disable
performance collection. AMA uninstall was requested but has not been verified.

Path selected: Microsoft Entra join, followed by Azure Monitor Agent (AMA)
deployed silently through Microsoft Intune. The Azure resources below have been
created. The Intune installer is now assigned to a dedicated single-device group.
Intune executed the installer successfully as SYSTEM. AMA 1.44.0.0 is running.
The DCR is associated at the approved 10-second fallback. Heartbeat and all 18
configured performance counter types are arriving from CONTOSO-PC. Observed
processor-total record spacing is approximately 10 seconds.

## Intune deployment
 
See [Visualization scripts](#visualization-scripts) for ready-to-run charts in
the workspace Logs view.

Assignment read-back succeeded at `2026-09-24T17:53:28.5810482Z` (timestamp
reported by the administration host). The device-run-state report was empty and
neither `AzureMonitorAgent` nor `IntuneManagementExtension` was present at the
post-assignment check. Assignment success is not installation success.

After the operator's Windows MDM sync, `IntuneManagementExtension` was installed
and Running with Automatic startup on 2026-09-25 (local time). AMA was still absent
at the first post-sync check. IME logs show a successful gateway TLS connection,
`NotInEsp`, and a 90-second startup delay before the first PowerShell/Win32
check-in. A separate randomized PowerShell timer was also logged. These are
scheduling observations, not evidence that the installer has executed or failed.
No enrollment repair or local installation was necessary to bootstrap IME.

The subsequent AgentExecutor log confirms policy
`88888888-8888-8888-8888-888888888888` ran through Intune in 64-bit SYSTEM
PowerShell and exited 0 at local `2026-09-25T01:00:35+07:00`.
Installed AMA version: `1.44.0.0`; product code:
`{C4F6939C-A3A2-4556-AEB6-889F720A8AB8}`. Installer MSI SHA256:
`A93A6F55F8179BE097184630E999D537EAE2B8098DA9C00101BA1BF9A9D55927`.
The Microsoft signature was verified before installation. Service state was
independently verified as Running, Automatic. The Intune cloud run-state report
was still empty at the first check; local execution evidence is the current
installation proof. No restart or Windows-profile switch was performed.

Post-activation verification: all nine documented KQL queries were accepted by
the live Log Analytics API. Initial empty results were followed by actual
Heartbeat and Perf records without local remediation. The non-elevated session
cannot enumerate `C:\Resources\Azure Monitor Agent`, but protected logs are no
longer needed to establish delivery. No ACLs were weakened and no elevation was
launched automatically.

Verified ingestion on 2026-09-25 local time:

- Device: `CONTOSO-PC`; all 18 configured ObjectName/CounterName pairs present,
  covering Processor, Memory, LogicalDisk, PhysicalDisk, and Process.
- Perf: 83,670 records from `2026-09-24T18:06:44.0854598Z` through
  `2026-09-24T18:13:34.1055965Z`, totaling 12.8345 MiB billable data.
- Heartbeat: 7 records, latest `2026-09-24T18:13:43.9314285Z` in that check.
- Processor total: 39 records in the spacing check; gaps minimum 9.995 seconds,
  median 9.997 seconds, maximum 10.014 seconds.
- `SampleCount` and bucket timestamps were null in the observed records. Do not
  interpret null aggregation metadata as proof that every raw measurement is
  retained. One-second stored granularity remains untested.
- The initial Perf rate extrapolates to about 2.6 GiB/day if sustained, not a
  reliable forecast. At that rate the existing 1 GB/day cap could be reached in
  roughly 9 hours, causing collection gaps until the cap resets. The cap remains
  unchanged; reducing process counters or using 60 seconds can reduce volume.

| Item | Value |
| --- | --- |
| Group | Contoso-AMA-CONTOSO-PC |
| Group ID | 77777777-7777-7777-7777-777777777777 |
| Only member, directory object ID | 66666666-6666-6666-6666-666666666666 |
| Intune script | Contoso - Install AMA - CONTOSO-PC |
| Script ID | 88888888-8888-8888-8888-888888888888 |
| Installer source SHA256 | Recompute for the customized file; the original hash does not describe this sanitized source. |
| Execution | SYSTEM, 64-bit PowerShell, no forced reboot |
| Script signature enforcement | Disabled for this unsigned lab script; downloaded installers require valid Microsoft signatures |

[scripts/Publish-IntuneAgent.ps1](scripts/Publish-IntuneAgent.ps1) verifies the
operator, tenant, permissions, Intune identity, and single-device membership. It
checks uploaded bytes and settings before assigning. Reruns reuse identical
project objects; unexpected members, content, or assignments cause refusal
rather than overwrite. It uses Graph beta. `-WhatIf` previews the next required
write and returns when later steps depend on that object.

```powershell
.\scripts\Publish-IntuneAgent.ps1 -WhatIf
.\scripts\Publish-IntuneAgent.ps1
```

[scripts/Install-AzureMonitorAgent.ps1](scripts/Install-AzureMonitorAgent.ps1)
is delivered by Intune, not run locally by the administrator. It requires SYSTEM,
64-bit PowerShell, this computer name, and the verified Entra tenant/device IDs
with successful device authentication. It downloads the
[official AMA client MSI](https://go.microsoft.com/fwlink/?linkid=2192409)
and, if missing, the
[Microsoft VC++ x64 runtime](https://aka.ms/vs/17/release/vc_redist.x64.exe).
Both downloads require valid Microsoft Corporation Authenticode signatures.

Staging and logs are under `%ProgramData%\ContosoDeviceMonitoring\<run-GUID>`,
restricted to SYSTEM and local Administrators. Existing directories with
unexpected owners, permissions, or reparse points are refused. The transcript
records hashes and signer; `ama-msi.log` records MSI details. Installation uses
`/qn /norestart`; exit codes 0 and 3010 are accepted, but success also requires
the AMA service to reach Running. Other failures return 1. Restart requirements
are logged, never forced. Successful downloads are removed; logs remain. The
installed version is logged from the uninstall registry.

An existing AMA service skips installation and is started if needed. This is
initial deployment, not automatic upgrading. Upgrades require a reviewed,
version-specific Intune revision; the publisher refuses changed content rather
than silently replacing it. To uninstall, first run the project `Stop` control
and remove its Intune assignment, then deploy an uninstall through Intune using
the installed product's verified MSI product code with
`msiexec /x {PRODUCT-CODE} /qn /norestart`. Do not guess the product code or use
`Win32_Product` for inventory. Removing an assignment alone does not uninstall.
Do not delete the tenant monitored object or unrelated associations.

Completed delivery step: Windows Settings > Accounts > Access work or school >
the existing managed Contoso connection > Info > Sync. Do not disconnect either
identity. MDM sync is a bootstrap/delivery step, not proof of script execution.
Check the project platform script's Device status in Intune, then confirm both
local services. If delivery remains absent, investigate IME eligibility and
enrollment before changing or deleting records. No local installation workaround
has been used.

## Azure deployment (2026-09-24)

- Subscription: Application, 22222222-2222-2222-2222-222222222222.
- Region selected by the operator: Indonesia Central (`indonesiacentral`).
- Resource group: `rg-contoso-device-monitoring-idc`.
- Log Analytics: `law-contoso-device-monitoring-idc`, PerGB2018, 30-day retention.
- DCR: `dcr-contoso-windows-performance`, Windows, Microsoft-Perf stream.
- Tenant monitored object: `/providers/Microsoft.Insights/monitoredObjects/11111111-1111-1111-1111-111111111111`.
- The monitored object, workspace, and DCR deployed successfully in Indonesia
  Central. No privilege elevation or role assignment was required.
- The DCR is now associated at 10-second sampling using association
  `contoso-windows-performance`. Read-back at `2026-09-24T18:02:44Z` confirmed
  one project association and zero other associations on the monitored object.
  Azure previously accepted one-second configuration, but this does not prove
  one-second stored granularity. The approved 10-second fallback is active.
- A one-second diagnostic must be bounded when activated; it is not a permanent
  unattended collection setting. No diagnostic collection is active yet.
- Workspace daily ingestion cap: 1 GB as a lab safety measure. This can stop
  ingestion and create gaps. It is not a precise budget or guaranteed cost ceiling;
  overshoot and charges are possible. Review measured usage before changing it.
- All 18 configured counter paths were tested locally: 1,948 samples, zero invalid
  samples. Counter count varies with running processes. This is not ingestion proof.

Reproducible resource definitions: [infra/azuredeploy.json](infra/azuredeploy.json)
and [infra/monitored-object.json](infra/monitored-object.json).

```powershell
az deployment group create --name contoso-performance --resource-group rg-contoso-device-monitoring-idc --subscription 22222222-2222-2222-2222-222222222222 --template-file infra/azuredeploy.json --parameters samplingSeconds=10 # Replace the example subscription ID and resource names.
```

The template defaults to 10 seconds if no interval is provided. The initial
unassociated one-second configuration was changed to 10 before activation.

## Change interval or stop collection

Use [scripts/Set-MonitoringCollection.ps1](scripts/Set-MonitoringCollection.ps1)
from an administration PowerShell session with Azure CLI signed in as the
Contoso operator. This is not an Intune endpoint script and does not install or
stop Windows services. Azure RBAC must permit updating the project DCR and
creating/deleting associations on the tenant monitored object; Graph permissions alone
do not grant that access. No local elevation is required.

```powershell
$SamplingSeconds = 15
.\scripts\Set-MonitoringCollection.ps1 -Action SetInterval -SamplingSeconds $SamplingSeconds
.\scripts\Set-MonitoringCollection.ps1 -Action Status
.\scripts\Set-MonitoringCollection.ps1 -Action Stop
.\scripts\Set-MonitoringCollection.ps1 -Action Start -AcknowledgeTenantScope
```

- `SetInterval` updates only the `windowsPerformance` source's sampling interval
  and reads it back. Counter paths, destinations, and other DCR settings are
  preserved. It does not start collection when the rule is unassociated.
- Custom positive whole seconds replace the previous 1/10/60-only presets.
  Zero, negative values, fractional seconds, and values above the 32-bit integer
  limit are rejected locally. Azure may impose additional service limits; an
  API rejection is reported, not silently replaced with another interval.
- The template's `samplingSeconds` parameter also accepts custom positive whole
  seconds. A later template deployment resets the interval to its supplied value
  (or the default 10 seconds), so pass your chosen value when redeploying.
- `Stop` deletes all associations linking this tenant monitored object to this
  exact project DCR. Associations for other rules are untouched. Repeated calls
  are safe. It retains the agent installation, DCR, workspace, and historical
  data. It does not disable other rules or guarantee that agent heartbeat stops.
- `Start` creates the project association only if absent, rejects a conflicting
  association name, and requires explicit `-AcknowledgeTenantScope`. It preserves
  the interval. It refuses a one-second baseline to avoid starting an unbounded
  diagnostic; set a baseline interval such as 10 before starting. Any later
  one-second `SetInterval` change must be operator-supervised and restored.
- Add `-WhatIf` to preview either change. `Status` performs no writes and reports
  the interval and association counts; `ConfigurationAssociated` is not proof
  that an agent is collecting or that records are arriving.
- Sampling is the time between measurements, **not the upload/send interval**.
  AMA controls batching and ingestion latency. These commands cannot promise an
  upload every N seconds or unaggregated records at that spacing.
- Changes apply after agent configuration refresh, not immediately. Buffered
  records may arrive after stopping. Offline devices cannot receive the change
  until they reconnect. Verify actual cessation using new `Perf.TimeGenerated`
  values, not just ingestion timestamps.
- Client-installer associations apply tenant-wide to AMA client installations,
  not just the Intune target group. Changing the interval affects every consumer
  of this DCR. Coordinate changes with other administrators.

To resume after stopping, use `-Action Start -AcknowledgeTenantScope`, which follows the
[Microsoft client association procedure](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-windows-client#step-3-associate-the-dcr-to-the-monitored-object)
after reviewing tenant scope. `SetInterval` intentionally does not recreate it.
Do not leave one-second diagnostics running unattended.

Validation on 2026-09-24: local tests cover custom intervals, invalid inputs,
payload preservation, WhatIf, scoped deletion, and repeated stopping. Azure
accepted and read back 7 seconds on the inactive DCR. Start scope, collision,
one-second-baseline, WhatIf, and repeated-start tests also pass. Agent-level
interval and stop propagation still require telemetry verification.
Run the non-installing tests with:

```powershell
.\tests\Test-DeploymentScripts.ps1
```

## Verified preflight (2026-09-24)

| Item | Observed result |
| --- | --- |
| Device | CONTOSO-PC |
| OS | Windows 11 Pro, 64-bit, version 10.0.26200 |
| Logical processors | 12 |
| Current terminal | Not elevated |
| Entra state | AzureAdJoined: YES; DeviceAuthStatus: SUCCESS; WorkplaceJoined: YES |
| Tenant | Contoso, 11111111-1111-1111-1111-111111111111 |
| Joined device ID | 33333333-3333-3333-3333-333333333333 |
| Registered device ID | 44444444-4444-4444-4444-444444444444 |
| Local MDM evidence | MS DM Server enrollment entry present |
| Intune cloud validation | Read-only Graph login succeeded; exactly one managed device, CONTOSO-PC |
| Intune managed device ID | 55555555-5555-5555-5555-555555555555 |
| Intune associated Entra device ID | 44444444-4444-4444-4444-444444444444 (older workplace identity) |
| Intune Management Extension | No service returned by the local service lookup |
| Requested subscription | Application, 22222222-2222-2222-2222-222222222222; live ARM read succeeded; Enabled |
| Tenant AMA monitored object | Created in Indonesia Central; provisioningState Succeeded |

The cloud inventory at 2026-09-24T16:00:37Z confirms the single Intune device
uses managementAgent `mdm` and the requested Contoso user. Entra reports the
workplace record as enabled, managed, and compliant. The new joined record is
enabled with trustType `AzureAd`, but its managed/compliant properties are null.
Do not treat the two directory records as two physical devices or assign solely
to the new identity without confirming Intune delivery. Enrollment has not been
removed or repaired; subsequent Intune installation through that record succeeded.

The inventory is collected by [scripts/Get-EnrollmentInventory.ps1](scripts/Get-EnrollmentInventory.ps1).
It checks the signed-in account and tenant, follows Intune pagination, and reads
both directory identities. It does not modify enrollment or assignments. The
optional `-DeploymentAccess` switch requests delegated
`DeviceManagementScripts.ReadWrite.All` and `Group.ReadWrite.All` for the later
deployment. The previous configuration write scope was rejected by the live
script API with HTTP 403; the API explicitly requires the script-specific scope.
Graph now uses its normal CurrentUser
authentication cache to reuse sign-in across administration jobs; no tokens are
written to project files or printed.
The initial Azure CLI Graph permissions failure was resolved using Microsoft
Graph Authentication 2.40.0 with read-only delegated device permissions.
NuGet 2.8.5.208 is installed. Graph signatures were verified as valid Microsoft
signatures; RemoteSigned was set only for the administration PowerShell process.
An independent PowerShell job completed sign-in after an earlier foreground
authentication attempt was canceled. Authentication tokens were not exported.

The operator completed Entra join on 2026-09-24. The successful device
authentication check was obtained before restarting or switching profiles.
The previous workplace registration and MDM enrollment entry remain present;
no registration or enrollment has been removed by this project. Confirm cloud
record identity before deciding whether enrollment repair is necessary.

## Interactive join prerequisite

AMA's Windows client installer requires Microsoft Entra join or hybrid join.
Intune enrollment and Entra registration alone do not satisfy this prerequisite.
The agent uses device authentication, so changing the daily Windows account is
not inherently required. First Windows sign-in with a work account creates a
separate profile; the existing profile is not automatically migrated.

Join procedure retained for reference (join is now verified):

1. Back up important files and ensure any BitLocker/device-encryption recovery
   key is accessible privately. Do not paste credentials or recovery keys into chat.
2. Verify the existing account's password, not only its PIN. Establish and test
   a separate local administrator recovery account through Windows Settings
   before changing enrollment. Keep its credentials private.
3. Review Settings > Accounts > Access work or school. Existing MDM enrollment
   may block the join option. Do not disconnect, retire, wipe, or delete the
   device merely to bypass an error; first review its cloud enrollment and
   plan reenrollment, since disconnecting can remove managed settings or access.
4. If available, select Connect > Join this device to Microsoft Entra ID
   (older UI: Azure Active Directory). Use
   admin@contoso.example and verify the organization is Contoso.
   Enter passwords and complete MFA only in Microsoft's Windows sign-in UI.
5. Complete any required restart. Keep the existing Windows profile; do not
   delete accounts or migrate profile folders as part of this project.
6. Run `dsregcmd /status`. The required result is `AzureAdJoined : YES`,
   the intended tenant ID, and `DeviceAuthStatus : SUCCESS` where available.
   Revalidate the Intune record and enrollment before deploying AMA.

An error or missing join option requires investigation, not a forced join or
registry modification. Windows elevation and interactive sign-in are performed
by the operator, not by the assistant.

## Remaining validation

- A bounded one-second diagnostic and its actual stored granularity remain
  untested. The approved 10-second fallback is verified and remains active.
- Stop/start controls have local safety tests and Azure read-back verification;
  actual agent stop-propagation timing has not been measured.
- Review a longer ingestion-volume sample before changing the daily cap or
  making a cost forecast. The initial rate can exhaust the lab cap within a day.

## Visualization scripts

Open the Log Analytics workspace `law-contoso-device-monitoring-idc` in Azure
Portal, select **Logs**, switch to **KQL mode** if necessary, and run the complete
contents of one file at a time. Each file ends with `render` to request its chart.
Use a portal time range at least as large as `Lookback` (or **Set in query** where
available). Charts are query results, not deployed dashboards or scheduled alerts.

| Script | Visualization | Useful question |
| --- | --- | --- |
| [01-resource-pressure.kql](queries/01-resource-pressure.kql) | CPU and physical RAM averages/peaks | Was the device CPU-bound or short of physical memory? |
| [02-top-process-cpu.kql](queries/02-top-process-cpu.kql) | Top 10 process-name groups, horizontal bars | Which names consumed the most CPU while observed? |
| [03-process-memory-trends.kql](queries/03-process-memory-trends.kql) | Top 5 private working-set trends | Which names have sustained or growing physical memory use? |
| [04-disk-latency.kql](queries/04-disk-latency.kql) | Read/write latency by physical disk | When did disk response time rise? |
| [05-disk-free-space.kql](queries/05-disk-free-space.kql) | Free-space trends per volume | Which volumes are running out of capacity? |
| [06-disk-throughput.kql](queries/06-disk-throughput.kql) | Read/write MiB/sec by physical disk | Were latency spikes accompanied by heavy transfer activity? |
| [07-collection-coverage.kql](queries/07-collection-coverage.kql) | Observed versus expected CPU samples | Where are collection or delivery gaps? |
| [08-ingestion-volume.kql](queries/08-ingestion-volume.kql) | Stacked billable MiB by counter category | Which counters dominate ingestion volume? |

Edit the `let` variables at the top of each file:

- `Device`: one device name, default `CONTOSO-PC`; its DNS-suffixed form also
  matches. Do not set it to an empty string to query all devices: CPU and memory
  constants are device-specific and these charts deliberately target one PC.
- `Lookback`: query duration, such as `1h`, `4h`, or `24h`.
- `Grain`: chart bucket, such as `1m` or `5m`. For coverage, keep Lookback an
  integer multiple of Grain. This changes visualization aggregation, not AMA's
  collection interval.
- `LogicalProcessors = 8.0` and `TotalPhysicalBytes = 17179869184.0` are example
  hardware values. Replace them with measurements from the target device.
- `TopCount`: number of process-name groups displayed.
- `ExpectedSamplingSeconds = 10.0`: update the coverage query when changing the
  DCR interval. A mixed-interval historical window needs separate queries.

Interpretation notes:

- Process queries sum records sharing a name and exact sample timestamp, then
  aggregate those snapshots. They group the reported `InstanceName`, not unique
  PID lifetimes, and do not merge differently suffixed names. A CPU average is
  conditional on the name being observed, not an average including time absent.
  Missing data is not imputed as zero in resource charts. Name/PID reuse and
  restarts mean a rising memory line is not, by itself, proof of a memory leak.
- CPU percentages for processes are normalized by logical processor count.
  Processor `_Total` is already normalized. RAM usage is physical memory, not
  committed-memory percentage or the sum of process private bytes.
- Disk latency is milliseconds converted from seconds. Peak sample latency is
  the maximum sampled *average* counter, not the slowest individual I/O. Reads
  and writes have separate series; `_Total` is excluded to avoid double counting.
- Coverage zero-fills missing completed buckets, including time before collection
  began. Recent buckets can fill later due to ingestion delay. Gaps can reflect
  sleep, offline time, daily caps, or delayed delivery, not necessarily agent
  failure. Duplicate identical CPU timestamps are deduplicated; values above
  100% can still indicate faster sampling or another collection source.
- Ingestion uses `ingestion_time()` and billable bytes, not the measurement time
  or monetary cost. The current bucket is partial. Scope is this device's Perf
  and Heartbeat, not all workspace billable data or the daily cap's reset window.
  The validated sample was dominated by Process counters.

Validation: the original, configured versions of all eight files executed through the live Log Analytics
API on 2026-09-25 local time and returned nonempty results. API validation checks
query semantics and result shape; Azure Portal chart rendering was not inspected.
Running these queries changes no collection settings and creates no Azure resources.

## Collection decisions and limitations

Validation queries (run separately in workspace Logs). All nine queries passed
live validation on 2026-09-25 local time. Initial results were empty before first
ingestion. Query acceptance does not prove agent delivery.

```kusto
Heartbeat
| where TimeGenerated > ago(1h)
| where Computer =~ "CONTOSO-PC" or Computer startswith "CONTOSO-PC." // Replace both names with your target Computer value.
| where Category == "Azure Monitor Agent"
| summarize LastHeartbeat=max(TimeGenerated) by Computer, SourceComputerId, Version
```

Raw counter history retains units and process identity evidence:

```kusto
Perf
| where TimeGenerated > ago(15m)
| where Computer =~ "CONTOSO-PC" or Computer startswith "CONTOSO-PC." // Replace both names with your target Computer value.
| project TimeGenerated, Computer, ObjectName, InstanceName, CounterName,
          CounterValue, SampleCount, BucketStartTime, BucketEndTime
| order by TimeGenerated desc, ObjectName asc, InstanceName asc
| take 1000
```

Stored CPU record spacing and aggregation:

```kusto
Perf
| where TimeGenerated > ago(30m)
| where Computer =~ "CONTOSO-PC" or Computer startswith "CONTOSO-PC." // Replace both names with your target Computer value.
| where ObjectName == "Processor" and InstanceName == "_Total" and CounterName == "% Processor Time"
| order by Computer asc, TimeGenerated asc
| serialize
| extend GapSeconds=iff(Computer == prev(Computer), datetime_diff('millisecond', TimeGenerated, prev(TimeGenerated)) / 1000.0, real(null))
| project TimeGenerated, Computer, GapSeconds, SampleCount, BucketStartTime, BucketEndTime, CounterValue
```

Example hardware: 8 logical processors and 17,179,869,184 bytes physical RAM.
Divide raw process CPU percentage by the actual logical CPU count for machine-relative CPU use. Processor
`_Total` CPU is already normalized. Physical used-memory percentage is
`100 * (1 - AvailableMBytes * 1048576 / TotalPhysicalBytes)`; committed-memory percentage
is different. Measure the actual memory capacity before querying. Do not correlate
aggregated PID averages with process CPU or assume an instance name is permanent.

Current baseline: 10 seconds, the approved fallback. For lower ingestion volume,
consider 60 seconds. Use 1 second only for a bounded diagnostic after validating
overhead and actual stored granularity. Sampling interval is not ingestion latency.

### CPU and physical memory history

Processor total is already normalized. The memory calculation uses an example
RAM capacity that must be replaced with the target device's actual capacity.

```kusto
Perf
| where TimeGenerated > ago(4h)
| where Computer =~ "CONTOSO-PC" or Computer startswith "CONTOSO-PC." // Replace both names with your target Computer value.
| where ObjectName == "Processor" and InstanceName == "_Total" and CounterName == "% Processor Time"
| summarize CpuPercent=avg(CounterValue) by bin(TimeGenerated, 1m), Computer
| render timechart
```

```kusto
let TotalPhysicalBytes = 17179869184.0; // Example 16 GiB; replace with the target device's TotalPhysicalMemory.
Perf
| where TimeGenerated > ago(4h)
| where Computer =~ "CONTOSO-PC" or Computer startswith "CONTOSO-PC." // Replace both names with your target Computer value.
| where ObjectName == "Memory" and CounterName == "Available MBytes"
| extend UsedPhysicalPercent=100.0 * (1.0 - CounterValue * 1048576.0 / TotalPhysicalBytes)
| summarize UsedPhysicalPercent=avg(UsedPhysicalPercent) by bin(TimeGenerated, 1m), Computer
| render timechart
```

### Disk capacity and activity

The first query gives latest capacity readings; the second retains per-counter
units for activity history. Read/write rates are bytes/sec, average disk latency
is seconds, and current queue length is an outstanding-request count. Do not
place unlike units on a single unlabeled axis.

```kusto
Perf
| where TimeGenerated > ago(1h)
| where Computer =~ "CONTOSO-PC" or Computer startswith "CONTOSO-PC." // Replace both names with your target Computer value.
| where ObjectName == "LogicalDisk" and CounterName in ("% Free Space", "Free Megabytes")
| summarize arg_max(TimeGenerated, CounterValue) by Computer, InstanceName, CounterName
| order by Computer asc, InstanceName asc, CounterName asc
```

```kusto
Perf
| where TimeGenerated > ago(4h)
| where Computer =~ "CONTOSO-PC" or Computer startswith "CONTOSO-PC." // Replace both names with your target Computer value.
| where ObjectName == "PhysicalDisk"
| summarize Mean=avg(CounterValue), Peak=max(CounterValue) by bin(TimeGenerated, 1m), Computer, InstanceName, CounterName
| order by TimeGenerated desc, InstanceName asc, CounterName asc
```

### Process instance resource history

This ranks instance names within a minute, not stable process lifetimes. Use
the raw counter query above to inspect `ID Process`, `Elapsed Time`, sample
counts, and bucket boundaries before attributing a historical spike to a PID.
Aggregated PID values are not reliable identifiers. `Working Set - Private` and
`Private Bytes` have different meanings; neither is total system physical RAM.

```kusto
let LogicalProcessors = 8.0; // Replace with the target device's NumberOfLogicalProcessors.
Perf
| where TimeGenerated > ago(1h)
| where Computer =~ "CONTOSO-PC" or Computer startswith "CONTOSO-PC." // Replace both names with your target Computer value.
| where ObjectName == "Process" and InstanceName !in ("_Total", "Idle")
| summarize CpuPercentOfMachine=avgif(CounterValue / LogicalProcessors, CounterName == "% Processor Time"),
      PrivateWorkingSetMiB=avgif(CounterValue / 1048576.0, CounterName == "Working Set - Private"),
      PrivateBytesMiB=avgif(CounterValue / 1048576.0, CounterName == "Private Bytes"),
      ReadBytesPerSec=avgif(CounterValue, CounterName == "IO Read Bytes/sec"),
      WriteBytesPerSec=avgif(CounterValue, CounterName == "IO Write Bytes/sec")
  by bin(TimeGenerated, 1m), Computer, InstanceName
| order by TimeGenerated desc, CpuPercentOfMachine desc
| take 200
```

### Ingestion volume

Billable bytes are observed volume, not a monetary bill or a forecast. This
query covers the two project tables; workspace caps and charges can include
other data. Confirm pricing separately before increasing frequency or retention.

```kusto
union withsource=TableName Heartbeat, Perf
| where TimeGenerated > ago(24h)
| summarize Records=count(), BillableMiB=sumif(_BilledSize, _IsBillable =~ "true") / 1048576.0
  by bin(TimeGenerated, 1h), TableName
| order by TimeGenerated desc
```

For equal records per sample, 10-second sampling produces about six times the
volume of 60-second sampling; 1-second sampling produces about sixty times.
Log Analytics ingestion and retention incur charges. No cost estimate is yet
validated for this device.

Client-installer DCR associations apply to all devices in the tenant running
the AMA client installer, not just the Intune installation target group. Inspect
existing associations before changes. Client monitored-object APIs have preview
aspects. AMA is intended primarily for always-connected devices and has documented
laptop battery/network and hibernation limitations.

Performance counters are not an exact Task Manager recording. Process instance
names can repeat and PIDs can be reused. Short-lived processes can be missed
between samples. Process I/O can include more than physical disk activity.
Do not collect command lines or other unnecessary personal data by default.

## Evidence

Primary documentation inspected on 2026-09-24:

- [AMA Windows client requirements and configuration](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-windows-client)
- [Join an existing Windows device](https://support.microsoft.com/en-us/account-billing/join-your-work-device-to-your-work-or-school-network-ef4d6adb-5095-4e51-829e-5457430f3973)
- [Microsoft Entra device FAQ](https://learn.microsoft.com/en-us/entra/identity/devices/faq)
- [AMA performance counters](https://learn.microsoft.com/en-us/azure/azure-monitor/vm/data-collection-performance)
- [Intune PowerShell deployment](https://learn.microsoft.com/en-us/intune/intune-service/apps/powershell-scripts)

Confidence: high for the observed join state, Intune-delivered installation,
Heartbeat/Perf delivery, all 18 counter types, and approximately 10-second CPU
record spacing. One-second granularity, stop-propagation timing, and sustained
volume/cost projections remain unverified.