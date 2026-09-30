[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cc-switch-context.ps1')

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class CcSwitchContextJunctionTest {
    const uint GenericWrite = 0x40000000;
    const uint OpenExisting = 3;
    const uint BackupSemantics = 0x02000000;
    const uint OpenReparsePoint = 0x00200000;
    const uint FsctlSetReparsePoint = 0x000900A4;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[] input, uint inputLength, IntPtr output, uint outputLength, out uint returned, IntPtr overlapped);

    public static void CreateJunction(string link, string target) {
        Directory.CreateDirectory(link);
        string fullTarget = Path.GetFullPath(target);
        string substitute = "\\??\\" + fullTarget;
        byte[] sub = Encoding.Unicode.GetBytes(substitute);
        byte[] print = Encoding.Unicode.GetBytes(fullTarget);
        byte[] path = new byte[sub.Length + 2 + print.Length + 2];
        Buffer.BlockCopy(sub, 0, path, 0, sub.Length);
        Buffer.BlockCopy(print, 0, path, sub.Length + 2, print.Length);
        byte[] data = new byte[16 + path.Length];
        Buffer.BlockCopy(BitConverter.GetBytes(0xA0000003U), 0, data, 0, 4);
        Buffer.BlockCopy(BitConverter.GetBytes((ushort)(8 + path.Length)), 0, data, 4, 2);
        Buffer.BlockCopy(BitConverter.GetBytes((ushort)0), 0, data, 8, 2);
        Buffer.BlockCopy(BitConverter.GetBytes((ushort)sub.Length), 0, data, 10, 2);
        Buffer.BlockCopy(BitConverter.GetBytes((ushort)(sub.Length + 2)), 0, data, 12, 2);
        Buffer.BlockCopy(BitConverter.GetBytes((ushort)print.Length), 0, data, 14, 2);
        Buffer.BlockCopy(path, 0, data, 16, path.Length);
        using (SafeFileHandle handle = CreateFile(link, GenericWrite, 0, IntPtr.Zero, OpenExisting, BackupSemantics | OpenReparsePoint, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new IOException("Could not open synthetic junction", Marshal.GetExceptionForHR(Marshal.GetHRForLastWin32Error()));
            uint returned;
            if (!DeviceIoControl(handle, FsctlSetReparsePoint, data, (uint)data.Length, IntPtr.Zero, 0, out returned, IntPtr.Zero))
                throw new IOException("Could not set synthetic junction win32=" + Marshal.GetLastWin32Error(), Marshal.GetExceptionForHR(Marshal.GetHRForLastWin32Error()));
        }
    }
}
'@

$script:passed = 0
$script:failed = 0
$script:testRoot = Join-Path ([IO.Path]::GetPathRoot($PSScriptRoot)) ('.cc-switch-context-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($script:testRoot) | Out-Null

function Assert-ContextTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-ContextTest {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}

function Assert-ContextThrows {
    param([scriptblock]$Body, [string]$MessagePattern)
    $thrown = $false
    try { & $Body } catch { $thrown = $true; if ($_.Exception.Message -notlike $MessagePattern) { throw 'Unexpected generic failure category.' } }
    if (-not $thrown) { throw 'Expected operation to fail.' }
}

function Test-ContextWithin {
    param([string]$Path, [string]$Root)
    $p = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $r = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return [string]::Equals($p, $r, [StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith(($r + '\'), [StringComparison]::OrdinalIgnoreCase)
}

try {
    $stick = Join-Path $script:testRoot 'stick'
    $session = Join-Path $script:testRoot 'session'
    [IO.Directory]::CreateDirectory($stick) | Out-Null
    [IO.Directory]::CreateDirectory($session) | Out-Null

    $envBefore = @{}
    Get-ChildItem Env: | ForEach-Object { $envBefore[$_.Name] = $_.Value }

    Invoke-ContextTest 'creates a scoped context and all eight USB harness paths' {
        $ctx = New-CcSwitchPortableContext -StickRoot $stick -SessionRoot $session
        $preferenceBefore = $ErrorActionPreference
        $prepared = Initialize-CcSwitchPortableContext -Context $ctx
        Assert-ContextTest ($ErrorActionPreference -eq $preferenceBefore) 'Initialize changed caller ErrorActionPreference.'
        Assert-ContextTest (-not $prepared.GuiValidated) 'Context incorrectly claims GUI validation.'
        Assert-ContextTest (Test-Path -LiteralPath $prepared.SettingsPath -PathType Leaf) 'Settings file was not created.'
        foreach ($id in @('claude', 'codex', 'gemini', 'grok', 'opencode', 'openclaw', 'hermes', 'pi')) {
            Assert-ContextTest (Test-ContextWithin -Path $prepared.HarnessDirectories[$id] -Root $stick) "Harness path escaped StickRoot: $id"
            Assert-ContextTest (Test-Path -LiteralPath $prepared.HarnessDirectories[$id] -PathType Container) "Harness directory missing: $id"
        }
        foreach ($key in @('HOME', 'CC_SWITCH_TEST_HOME')) {
            Assert-ContextTest ((Test-ContextWithin -Path $prepared.Environment[$key] -Root $stick) -and ($prepared.Environment[$key] -eq $prepared.Home)) "Environment path escaped USB root: $key"
        }
        foreach ($key in @('APPDATA', 'LOCALAPPDATA', 'USERPROFILE', 'WEBVIEW2_USER_DATA_FOLDER', 'TEMP', 'TMP')) {
            Assert-ContextTest (Test-ContextWithin -Path $prepared.Environment[$key] -Root $session) "Environment path escaped SessionRoot: $key"
        }
        foreach ($key in @('CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'GEMINI_CLI_HOME')) {
            $id = @{ CLAUDE_CONFIG_DIR = 'claude'; CODEX_HOME = 'codex'; GEMINI_CLI_HOME = 'gemini' }[$key]
            $expected = if ($key -eq 'GEMINI_CLI_HOME') { Join-Path $stick 'harness\cc-switch\gemini' } else { $prepared.HarnessDirectories[$id] }
            Assert-ContextTest ((Test-ContextWithin -Path $prepared.Environment[$key] -Root $stick) -and ($prepared.Environment[$key] -eq $expected)) "$key override was not USB scoped."
            if ($key -eq 'GEMINI_CLI_HOME') { Assert-ContextTest ((Join-Path $prepared.Environment[$key] '.gemini') -eq $prepared.HarnessDirectories.gemini) 'Gemini CLI home must contain the configured .gemini directory.' }
        }
        Assert-ContextTest (-not $prepared.EnvironmentBlockComplete) 'Environment overlay was incorrectly labeled a complete environment block.'
        Assert-ContextTest (@($prepared.InheritedEnvironmentVariablesToRemove) -contains 'MINIMAX_DATA_DIR' -and @($prepared.InheritedEnvironmentVariablesToRemove) -contains 'MAVIS_DATA_DIR') 'Known MCode directory overrides must be removed from the child environment.'
        $plan = Get-CcSwitchPortableContextPlan -Context $ctx
        Assert-ContextTest (@($plan.InheritedEnvironmentVariablesToRemove) -contains 'MINIMAX_DATA_DIR' -and @($plan.InheritedEnvironmentVariablesToRemove) -contains 'MAVIS_DATA_DIR') 'Context plan omitted known MCode environment removals.'
        $settings = Get-Content -LiteralPath $prepared.SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-ContextTest ($settings.claudeConfigDir -eq $prepared.HarnessDirectories.claude) 'Claude path setting mismatch.'
        Assert-ContextTest ($settings.codexConfigDir -eq $prepared.HarnessDirectories.codex) 'Codex path setting mismatch.'
        Assert-ContextTest ($settings.geminiConfigDir -eq (Join-Path $prepared.Environment.GEMINI_CLI_HOME '.gemini')) 'Gemini config path must match the CLI home child directory.'
        Assert-ContextTest ($settings.visibleApps.claude -and -not $settings.visibleApps.'claude-desktop' -and -not $settings.visibleApps.codex) 'Visible app defaults are wrong.'
        Assert-ContextTest (-not $settings.launchOnStartup -and -not $settings.minimizeToTrayOnClose -and -not $settings.silentStartup -and -not $settings.enableLocalProxy -and -not $settings.enableClaudePluginIntegration -and -not $settings.sessionAutoSyncEnabled) 'Supported safety settings were not applied.'
    }

    Invoke-ContextTest 'does not mutate the parent process environment' {
        $envAfter = @{}
        Get-ChildItem Env: | ForEach-Object { $envAfter[$_.Name] = $_.Value }
        Assert-ContextTest ($envBefore.Count -eq $envAfter.Count) 'Environment variable count changed.'
        foreach ($name in $envBefore.Keys) { Assert-ContextTest ($envAfter.ContainsKey($name) -and $envAfter[$name] -ceq $envBefore[$name]) "Parent environment changed: $name" }
    }

    Invoke-ContextTest 'rebinds all managed paths after the USB root changes and allows repeated initialization' {
        $movedStick = Join-Path $script:testRoot 'stick-after-remount'
        Move-Item -LiteralPath $stick -Destination $movedStick
        $moved = New-CcSwitchPortableContext -StickRoot $movedStick -SessionRoot $session -HarnessIds @('claude')
        $first = Initialize-CcSwitchPortableContext -Context $moved
        for ($i = 0; $i -lt 2; $i++) {
            $again = Initialize-CcSwitchPortableContext -Context $moved
            Assert-ContextTest (-not $again.SettingsCreatedOrUpdated) 'Repeated initialization rewrote unchanged settings.'
        }
        $loaded = Get-Content -LiteralPath $first.SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entry in @{ claudeConfigDir='claude'; codexConfigDir='codex'; geminiConfigDir='gemini'; grokConfigDir='grok'; opencodeConfigDir='opencode'; openclawConfigDir='openclaw'; hermesConfigDir='hermes'; piConfigDir='pi' }.GetEnumerator()) {
            $expected = Join-Path $movedStick ('harness\cc-switch\' + $entry.Value)
            if ($entry.Key -eq 'geminiConfigDir') { $expected = Join-Path $expected '.gemini' }
            Assert-ContextTest ($loaded.($entry.Key) -eq $expected) "Path was not recalculated after remount: $($entry.Key)"
        }
    }

    Invoke-ContextTest 'recomputes mutable context fields, preserves unrelated settings, and keeps synthetic secrets out of output' {
        $stick2 = Join-Path $script:testRoot 'stick-existing'
        $session2 = Join-Path $script:testRoot 'session-existing'
        [IO.Directory]::CreateDirectory($stick2) | Out-Null
        [IO.Directory]::CreateDirectory($session2) | Out-Null
        $ctx = New-CcSwitchPortableContext -StickRoot $stick2 -SessionRoot $session2 -HarnessIds @('claude')
        $settingsParent = Split-Path -Parent $ctx.SettingsPath
        [IO.Directory]::CreateDirectory($settingsParent) | Out-Null
        $hostSentinel = Join-Path $script:testRoot 'must-not-be-written.json'
        [IO.File]::WriteAllText($hostSentinel, '{"sentinel":"untouched"}', (New-Object Text.UTF8Encoding($false)))
        $original = '{"claudeConfigDir":"C:\\host\\claude","launchOnStartup":true,"unrelated":"synthetic-secret-never-emit","webdavSync":{"password":"synthetic-password"}}'
        [IO.File]::WriteAllText($ctx.SettingsPath, $original, (New-Object Text.UTF8Encoding($false)))
        $ctx.SettingsPath = $hostSentinel
        $ctx.Settings.claudeConfigDir = $hostSentinel
        $output = @(Initialize-CcSwitchPortableContext -Context $ctx | Out-String)
        $outputText = $output -join ''
        Assert-ContextTest (-not $outputText.Contains('synthetic-secret-never-emit') -and -not $outputText.Contains('synthetic-password')) 'Synthetic secret leaked in command output.'
        $updated = Get-Content -LiteralPath (Join-Path $ctx.Home '.cc-switch\settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-ContextTest ($updated.claudeConfigDir -eq (Join-Path $stick2 'harness\cc-switch\claude')) 'Managed path was not forced back under StickRoot.'
        Assert-ContextTest ($updated.unrelated -eq 'synthetic-secret-never-emit') 'Unrelated setting was not preserved.'
        Assert-ContextTest ($updated.webdavSync.password -eq 'synthetic-password') 'Unrelated credential field was not preserved.'
        Assert-ContextTest ($updated.launchOnStartup -eq $false) 'Supported safety value was not updated.'
        Assert-ContextTest ((Get-Content -LiteralPath $hostSentinel -Raw) -eq '{"sentinel":"untouched"}') 'Tampered context wrote outside its roots.'
        $managedSettingsPath = Join-Path $ctx.Home '.cc-switch\settings.json'
        Assert-ContextTest (Test-Path -LiteralPath ($managedSettingsPath + '.cc-switch.bak') -PathType Leaf) 'Previous settings were not retained in a backup.'
        $unresolvedTemp = $managedSettingsPath + '.cc-switch.tmp'
        [IO.File]::WriteAllText($unresolvedTemp, '{}', (New-Object Text.UTF8Encoding($false)))
        Assert-ContextThrows { Initialize-CcSwitchPortableContext -Context $ctx } '*unresolved settings transaction temp*'
        Remove-Item -LiteralPath $unresolvedTemp -Force
    }

    Invoke-ContextTest 'rejects missing roots, overlapping roots, and unsupported desktop ids' {
        $validStick = Join-Path $script:testRoot 'stick-after-remount'
        Assert-ContextThrows { New-CcSwitchPortableContext -StickRoot (Join-Path $script:testRoot 'missing') -SessionRoot $session } '*missing*'
        $nestedSession = Join-Path $validStick 'nested-session'
        [IO.Directory]::CreateDirectory($nestedSession) | Out-Null
        Assert-ContextThrows { New-CcSwitchPortableContext -StickRoot $validStick -SessionRoot $nestedSession } '*disjoint*'
        Assert-ContextThrows { New-CcSwitchPortableContext -StickRoot $validStick -SessionRoot $session -HarnessIds @('claude-desktop') } '*unsupported*'
        Assert-ContextThrows { Get-CcSwitchContextFullPath 'E:relative' } '*drive-absolute*'
        Assert-ContextThrows { New-CcSwitchPortableContext -StickRoot $validStick -SessionRoot ([IO.Path]::GetPathRoot($validStick)) } '*volume root*'
    }

    Invoke-ContextTest 'detects a junction in an ancestor even when the requested child does not exist' {
        $junctionTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('cc-switch-junction-test-' + [Guid]::NewGuid().ToString('N'))
        $target = Join-Path $junctionTestRoot 'target'
        $junction = Join-Path $junctionTestRoot 'junction-parent'
        [IO.Directory]::CreateDirectory($junctionTestRoot) | Out-Null
        [IO.Directory]::CreateDirectory($target) | Out-Null
        try {
            [CcSwitchContextJunctionTest]::CreateJunction($junction, $target)
            Assert-ContextThrows { Assert-CcSwitchContextPlainPath -Path (Join-Path $junction 'not-created\stick') } '*reparse point*'
        } finally {
            if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction, $false) }
            $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + '\'
            $resolvedJunctionTest = [IO.Path]::GetFullPath($junctionTestRoot)
            if (-not $resolvedJunctionTest.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Junction test cleanup escaped temporary storage.' }
            Remove-Item -LiteralPath $resolvedJunctionTest -Recurse -Force -ErrorAction Stop
        }
    }

    Invoke-ContextTest 'drive-root StickRoot planning preserves the volume separator without writing there' {
        $volumeStick = [IO.Path]::GetPathRoot($script:testRoot)
        $localSession = [IO.Path]::GetTempPath().TrimEnd('\', '/')
        $settingsPath = Join-Path (Join-Path $volumeStick 'config\cc-switch\home') '.cc-switch\settings.json'
        $existedBefore = Test-Path -LiteralPath $settingsPath
        $plan = New-CcSwitchPortableContext -StickRoot $volumeStick -SessionRoot $localSession
        Assert-ContextTest ($plan.PersistentRoot -eq (Join-Path $volumeStick 'config\cc-switch')) 'Drive root was normalized as a drive-relative path.'
        Assert-ContextTest ($plan.SettingsPath.StartsWith(($volumeStick + 'config\'), [StringComparison]::OrdinalIgnoreCase)) 'Drive-root settings path was not absolute.'
        Assert-ContextTest ((Test-Path -LiteralPath $plan.SettingsPath) -eq $existedBefore) 'Read-only plan changed settings-path existence.'
    }
} finally {
    $resolvedTest = [IO.Path]::GetFullPath($script:testRoot).TrimEnd('\', '/')
    $allowedParent = [IO.Path]::GetPathRoot($script:testRoot)
    $actualParent = [IO.Directory]::GetParent($resolvedTest).FullName
    if (-not [string]::Equals($actualParent, $allowedParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test cleanup escaped its dedicated drive-root child.' }
    $items = @(Get-ChildItem -LiteralPath $resolvedTest -Force -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($items.Count -gt 0) {
        foreach ($item in $items | Sort-Object { $_.FullName.Length } -Descending) {
            if ($item.PSIsContainer) { Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue }
        }
        $remaining = @(Get-ChildItem -LiteralPath $resolvedTest -Force -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        if ($remaining.Count -gt 0) { throw 'Test cleanup refused a tree containing a reparse point.' }
    }
    Remove-Item -LiteralPath $resolvedTest -Recurse -Force -ErrorAction Stop
}

Write-Host "`nCC Switch context checks: $script:passed passed, $script:failed failed."
if ($script:failed -gt 0) { exit 1 }
