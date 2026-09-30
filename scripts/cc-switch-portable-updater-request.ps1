Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if (-not ('CcPortableUpdaterInjectionNativeV1' -as [type])) {
    . (Join-Path $PSScriptRoot 'cc-switch-portable-updater-injection.ps1')
}

function Read-CcSwitchPortableUpdaterRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$State,
        [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedNonce,
        [Parameter(Mandatory=$true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedExeSha256,
        [Parameter(Mandatory=$true)][long]$ExpectedProcessStartTicks,
        [switch]$Consume
    )
    $root=[IO.Path]::GetFullPath([string]$State.FixtureRoot).TrimEnd('\')
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not [string]::Equals((Split-Path -Parent $root),$temp,[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $root) -notmatch '^aistick-ac-probe-[0-9a-f]{32}$') { throw 'Update request owner root is not the active temporary AppContainer fixture.' }
    $runtime=Join-Path $root 'runtime'
    $updates=Join-Path $runtime 'updates'
    $mailbox=Join-Path $updates 'portable-update.request'
    foreach ($path in @($root,$runtime,$updates)) {
        $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Update request path may not contain reparse points.' }
    }
    if (-not [IO.File]::Exists($mailbox)) { return $null }
    $file=Get-Item -LiteralPath $mailbox -Force -ErrorAction Stop
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint -or $file.Length -gt 512) { throw 'Update request is not a small ordinary file.' }

    $pidValue=[uint32]$State.ProcessId
    $process=[IntPtr]$State.ProcessHandle
    if ($process -eq [IntPtr]::Zero -or [CcPortableUpdaterInjectionNativeV1]::GetProcessId($process) -ne $pidValue) { throw 'Update request PID is not bound to the owner-held process handle.' }
    $image=New-Object Text.StringBuilder 32768;[uint32]$capacity=32768
    if (-not [CcPortableUpdaterInjectionNativeV1]::QueryFullProcessImageNameW($process,0,$image,[ref]$capacity) -or
        -not [string]::Equals([IO.Path]::GetFullPath($image.ToString()),[IO.Path]::GetFullPath((Join-Path $root 'app\cc-switch.exe')),[StringComparison]::OrdinalIgnoreCase)) { throw 'Requesting process is not the owned CC Switch fixture executable.' }
    [long]$created=0;[long]$exit=0;[long]$kernel=0;[long]$user=0
    if (-not [CcPortableUpdaterInjectionNativeV1]::GetProcessTimes($process,[ref]$created,[ref]$exit,[ref]$kernel,[ref]$user) -or [DateTime]::FromFileTimeUtc($created).Ticks -ne $ExpectedProcessStartTicks) { throw 'Request PID start time does not match this launch.' }
    $exe=Join-Path $root 'app\cc-switch.exe'
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $ExpectedExeSha256) { throw 'Requesting executable no longer matches its pinned hash.' }
    if (-not [AiStickAppContainerNative]::VerifyAppContainerToken([int]$pidValue,[string]$State.AppContainerSid,([string]$State.NetworkMode -eq 'InternetClient'))) { throw 'Requesting process AppContainer token or capabilities changed.' }

    $stream=$null
    try {
        for ($attempt=0; $attempt -lt 20 -and -not $stream; $attempt++) {
            try { $stream=New-Object IO.FileStream($mailbox,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None) }
            catch [IO.IOException] { if ($attempt -eq 19) { throw }; Start-Sleep -Milliseconds 25 }
        }
        if (-not $stream) { throw 'Owner could not obtain an exclusive read handle for the one-shot request.' }
        if ($stream.Length -gt 512) { throw 'Update request exceeded the fixed message bound.' }
        $bytes=New-Object byte[] ([int]$stream.Length)
        $read=0
        while ($read -lt $bytes.Length) { $count=$stream.Read($bytes,$read,$bytes.Length-$read);if ($count -le 0) { throw 'Update request was truncated while being read.' };$read+=$count }
    } finally { if ($stream) { $stream.Dispose() } }
    foreach ($byte in $bytes) { if ($byte -gt 0x7f) { throw 'Update request must be ASCII with no BOM.' } }
    $actual=[Text.Encoding]::ASCII.GetString($bytes)
    $expected="{`"schema`":1,`"kind`":`"portableUpdateRequested`",`"pid`":$pidValue,`"nonce`":`"$ExpectedNonce`"}`n"
    if (-not [string]::Equals($actual,$expected,[StringComparison]::Ordinal)) { throw 'Update request did not match the exact schema, PID, and launch nonce.' }
    if ($Consume) { [IO.File]::Delete($mailbox) }
    return [pscustomobject]@{Requested=$true;ProcessId=$pidValue;Consumed=[bool]$Consume;MailboxPath=$mailbox}
}

function Read-CcSwitchPortableUpdaterRequestFromMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$FixtureRoot,
        [Parameter(Mandatory=$true)][uint32]$ProcessId,
        [Parameter(Mandatory=$true)][string]$AppContainerSid,
        [Parameter(Mandatory=$true)][ValidateSet('None','InternetClient')][string]$NetworkMode,
        [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedNonce,
        [Parameter(Mandatory=$true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedExeSha256,
        [Parameter(Mandatory=$true)][long]$ExpectedProcessStartTicks,
        [switch]$Consume
    )
    $handle=[CcPortableUpdaterInjectionNativeV1]::OpenProcess(0x1000,$false,$ProcessId)
    if ($handle -eq [IntPtr]::Zero) { throw 'Cannot open the expected live CC Switch process for event attribution.' }
    try {
        $state=[pscustomobject]@{FixtureRoot=$FixtureRoot;ProcessId=$ProcessId;ProcessHandle=$handle;AppContainerSid=$AppContainerSid;NetworkMode=$NetworkMode}
        return Read-CcSwitchPortableUpdaterRequest -State $state -ExpectedNonce $ExpectedNonce -ExpectedExeSha256 $ExpectedExeSha256 -ExpectedProcessStartTicks $ExpectedProcessStartTicks -Consume:$Consume
    } finally { [CcPortableUpdaterInjectionNativeV1]::CloseHandle($handle) | Out-Null }
}
