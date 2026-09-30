# Capability probe only: creates and removes an empty, uniquely owned profile.
# Does not launch CC Switch, grant filesystem permissions, or install services/drivers.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('AiStickProfileProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AiStickProfileProbe {
    [DllImport("userenv.dll", CharSet=CharSet.Unicode)]
    public static extern int CreateAppContainerProfile(string name, string displayName, string description, IntPtr capabilities, uint capabilityCount, out IntPtr sid);
    [DllImport("userenv.dll", CharSet=CharSet.Unicode)]
    public static extern int DeleteAppContainerProfile(string name);
    [DllImport("advapi32.dll")]
    public static extern IntPtr FreeSid(IntPtr sid);
}
'@
}

$moniker = 'AiStick.CapabilityProbe.' + [guid]::NewGuid().ToString('N')
$sid = [IntPtr]::Zero
$created = $false
$createResult = $null
$deleteResult = $null
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
try {
    $createResult = [AiStickProfileProbe]::CreateAppContainerProfile($moniker, 'AI Stick capability probe', 'Temporary empty profile; no application launch', [IntPtr]::Zero, 0, [ref]$sid)
    $created = ($createResult -eq 0)
} finally {
    if ($sid -ne [IntPtr]::Zero) { [void][AiStickProfileProbe]::FreeSid($sid) }
    if ($created) { $deleteResult = [AiStickProfileProbe]::DeleteAppContainerProfile($moniker) }
}

[pscustomobject]@{
    Elevated = $isAdmin
    ProfileCreated = $created
    CreateHResult = ('0x{0:X8}' -f $createResult)
    ProfileRemoved = ($created -and $deleteResult -eq 0)
    DeleteHResult = $(if ($null -ne $deleteResult) { '0x{0:X8}' -f $deleteResult } else { $null })
    ApplicationCompatibilityVerified = $false
    UsbFilesystemAccessVerified = $false
    ResidualProfileName = $(if ($created -and $deleteResult -ne 0) { $moniker } else { $null })
}
if (-not $created -or $deleteResult -ne 0) { exit 1 }
