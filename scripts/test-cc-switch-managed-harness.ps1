[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cc-switch-context.ps1')
. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-harness-runtime.ps1')

$script:passed = 0
$script:failed = 0
$root = New-AppContainerProbeFixtureRoot
$guidText = (Split-Path -Leaf $root).Substring('aistick-ac-probe-'.Length)
function Assert-ManagedHarness { param([bool]$Ok,[string]$Message) if (-not $Ok) { throw $Message } }
function Invoke-ManagedHarnessTest { param([string]$Name,[scriptblock]$Body) try { & $Body; $script:passed++; Write-Host "PASS $Name" } catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)"; Write-Host $_.ScriptStackTrace } }
function New-TestClaudeExe([string]$Directory,[string]$Version='2.1.1') {
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not [IO.File]::Exists($vswhere)) { throw 'Synthetic PE tests require the installed Visual Studio vswhere/compiler tools.' }
    $install = (& $vswhere -latest -products '*' -property installationPath | Select-Object -First 1).Trim()
    if (-not $install) { throw 'Visual Studio compiler installation was not found.' }
    $devCmd = Join-Path $install 'Common7\Tools\VsDevCmd.bat'
    if (-not [IO.File]::Exists($devCmd)) { throw 'Visual Studio x64 developer environment is missing.' }
    $source = Join-Path $Directory 'fixture.cpp'
    $resource = Join-Path $Directory 'fixture.rc'
    $padding = Join-Path $Directory 'padding.bin'
    $res = Join-Path $Directory 'fixture.res'
    $exe = Join-Path $Directory 'claude.exe'
    $batch = Join-Path $Directory 'build.cmd'
    [IO.File]::WriteAllText($source,'int main(){return 0;}',(New-Object Text.ASCIIEncoding))
    [IO.File]::WriteAllBytes($padding,(New-Object byte[] 1100000))
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Synthetic PE test version is invalid.' }
    $numericVersion = $Version.Replace('.',',') + ',0'
    $stringVersion = $Version + '.0'
    $rcText = @'
#include <windows.h>
1 RCDATA "padding.bin"
VS_VERSION_INFO VERSIONINFO
 FILEVERSION __NUMERIC_VERSION__
 PRODUCTVERSION __NUMERIC_VERSION__
 FILEFLAGSMASK 0x3fL
 FILEFLAGS 0
 FILEOS VOS_NT_WINDOWS32
 FILETYPE VFT_APP
 FILESUBTYPE VFT2_UNKNOWN
BEGIN
 BLOCK "StringFileInfo"
 BEGIN
  BLOCK "040904B0"
  BEGIN
   VALUE "FileVersion", "__STRING_VERSION__\0"
   VALUE "ProductVersion", "__STRING_VERSION__\0"
  END
 END
 BLOCK "VarFileInfo"
 BEGIN
  VALUE "Translation", 0x0409, 1200
 END
END
'@
    $rcText = $rcText.Replace('__NUMERIC_VERSION__',$numericVersion).Replace('__STRING_VERSION__',$stringVersion)
    [IO.File]::WriteAllText($resource,$rcText,(New-Object Text.ASCIIEncoding))
    $batchText = "@echo off`r`ncall `"$devCmd`" -arch=x64 -host_arch=x64 >nul`r`nif errorlevel 1 exit /b 10`r`nrc /nologo /fo `"$res`" `"$resource`"`r`nif errorlevel 1 exit /b 11`r`ncl /nologo /MT /O1 `"$source`" `"$res`" /link /out:`"$exe`"`r`nexit /b %errorlevel%`r`n"
    [IO.File]::WriteAllText($batch,$batchText,(New-Object Text.ASCIIEncoding))
    & $env:ComSpec /d /s /c ('"' + $batch + '"') | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or -not [IO.File]::Exists($exe)) { throw ('Native compiler could not produce the version-resource fixture (exit {0}).' -f $exitCode) }
    $info = (Get-Item -LiteralPath $exe).VersionInfo
    if ([string]$info.ProductVersion -cne $stringVersion -or [string]$info.FileVersion -cne $stringVersion -or (Get-Item -LiteralPath $exe).Length -lt 1000000) { throw 'Compiled fixture executable does not contain the required real PE version metadata.' }
    return $exe
}
function Write-TestClaudeCmd([string]$Path,[string]$RelativeTarget) {
    $text = "@ECHO off`r`nGOTO start`r`n:find_dp0`r`nSET dp0=%~dp0`r`nEXIT /b`r`n:start`r`nSETLOCAL`r`nCALL :find_dp0`r`n`"%dp0%\$RelativeTarget`"   %*`r`n"
    [IO.File]::WriteAllText($Path,$text,(New-Object Text.ASCIIEncoding))
}

try {
    $stick = Join-Path $root 'stick'
    $runtime = Join-Path $root 'runtime'
    $session = Join-Path $runtime 'session'
    $harness = Join-Path $root 'harness'
    $app = Join-Path $root 'app'
    $slotId = '2.1.1'
    $testExe = New-TestClaudeExe (Join-Path $root 'compiler-fixture')
    $testExeNew = New-TestClaudeExe (Join-Path $root 'compiler-fixture-2.1.2') '2.1.2'
    $slot = Join-Path $harness ('slots\' + $slotId)
    foreach ($path in @($stick,$runtime,$session,$harness,$app,(Join-Path $runtime 'node'),(Join-Path $runtime 'node\node_modules\npm\bin'),$slot,(Join-Path $slot 'node_modules\@anthropic-ai\claude-code'),(Join-Path $slot 'node_modules\@anthropic-ai\claude-code\bin'),(Join-Path $slot 'node_modules\@anthropic-ai\claude-code\node_modules\@anthropic-ai\claude-code-win32-x64'))) { [IO.Directory]::CreateDirectory($path) | Out-Null }
    [IO.File]::WriteAllText((Join-Path $app 'cc-switch.exe'),'synthetic executable',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $runtime 'node\node.exe'),'synthetic node',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $runtime 'node\node_modules\npm\bin\npm-cli.js'),'synthetic npm',(New-Object Text.UTF8Encoding($false)))
    $slotPackageRoot = Join-Path $slot 'node_modules\@anthropic-ai\claude-code'
    $nestedExe = Join-Path $slotPackageRoot 'node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe'
    [IO.File]::WriteAllText((Join-Path $slotPackageRoot 'package.json'),'{"name":"@anthropic-ai/claude-code","version":"2.1.1"}',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $slotPackageRoot 'node_modules\@anthropic-ai\claude-code-win32-x64\package.json'),'{"name":"@anthropic-ai/claude-code-win32-x64","version":"2.1.1"}',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllBytes((Join-Path $slotPackageRoot 'bin\claude.exe'),(New-Object byte[] 128))
    [IO.File]::Copy($testExe,$nestedExe)
    Write-TestClaudeCmd (Join-Path $slot 'claude.cmd') 'node_modules\@anthropic-ai\claude-code\node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe'

    Invoke-ManagedHarnessTest 'command target selects nested native executable over USB placeholder bin' {
        $check = Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $harness -SlotId $slotId
        Assert-ManagedHarness ($check.Valid -and [string]::Equals($check.ExecutablePath,$nestedExe,[StringComparison]::OrdinalIgnoreCase)) 'Valid nested npm target was not selected.'
    }
    Invoke-ManagedHarnessTest 'npm-generated bin cmd target is accepted only when its PE versions match' {
        $binExe = Join-Path $slotPackageRoot 'bin\claude.exe'
        [IO.File]::Copy($testExe,$binExe,$true)
        $nodeExe = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\node\node.exe'
        $cmdShim = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\node\node_modules\npm\node_modules\cmd-shim\lib\index.js'
        if (-not [IO.File]::Exists($nodeExe) -or -not [IO.File]::Exists($cmdShim)) { throw 'Local bundled npm cmd-shim is required for its output compatibility test.' }
        $cmdShimJs = "require(process.argv[1])(process.argv[2],process.argv[3]).then(()=>process.exit(0),e=>{console.error(e.message);process.exit(1)})"
        & $nodeExe -e $cmdShimJs $cmdShim $binExe (Join-Path $slot 'claude')
        if ($LASTEXITCODE -ne 0) { throw 'Bundled npm cmd-shim did not generate the fixture command file.' }
        $check = Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $harness -SlotId $slotId
        Assert-ManagedHarness ($check.Valid -and [string]::Equals($check.ExecutablePath,$binExe,[StringComparison]::OrdinalIgnoreCase)) 'Npm-generated bin target was not selected.'
        [IO.File]::WriteAllBytes($binExe,(New-Object byte[] 128))
        Write-TestClaudeCmd (Join-Path $slot 'claude.cmd') 'node_modules\@anthropic-ai\claude-code\node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe'
    }
    Invoke-ManagedHarnessTest 'new package cannot retain an old nested cmd target or old PE version' {
        [IO.File]::WriteAllText((Join-Path $slotPackageRoot 'package.json'),'{"name":"@anthropic-ai/claude-code","version":"2.1.2"}',(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $slotPackageRoot 'node_modules\@anthropic-ai\claude-code-win32-x64\package.json'),'{"name":"@anthropic-ai/claude-code-win32-x64","version":"2.1.2"}',(New-Object Text.UTF8Encoding($false)))
        $rejected = $false; try { Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $harness -SlotId $slotId | Out-Null } catch { $rejected = $true }
        Assert-ManagedHarness $rejected 'Package version update with old executable was accepted.'
        [IO.File]::WriteAllText((Join-Path $slotPackageRoot 'package.json'),'{"name":"@anthropic-ai/claude-code","version":"2.1.1"}',(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $slotPackageRoot 'node_modules\@anthropic-ai\claude-code-win32-x64\package.json'),'{"name":"@anthropic-ai/claude-code-win32-x64","version":"2.1.1"}',(New-Object Text.UTF8Encoding($false)))
    }
    Invoke-ManagedHarnessTest 'new bin executable is not used when claude.cmd still names the old nested executable' {
        [IO.File]::Copy($testExeNew,(Join-Path $slotPackageRoot 'bin\claude.exe'),$true)
        [IO.File]::WriteAllText((Join-Path $slotPackageRoot 'package.json'),'{"name":"@anthropic-ai/claude-code","version":"2.1.2"}',(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $slotPackageRoot 'node_modules\@anthropic-ai\claude-code-win32-x64\package.json'),'{"name":"@anthropic-ai/claude-code-win32-x64","version":"2.1.2"}',(New-Object Text.UTF8Encoding($false)))
        $rejected = $false; try { Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $harness -SlotId $slotId | Out-Null } catch { $rejected = $true }
        Assert-ManagedHarness $rejected 'Old nested target was accepted while bin contained the newer executable.'
        [IO.File]::WriteAllBytes((Join-Path $slotPackageRoot 'bin\claude.exe'),(New-Object byte[] 128))
        [IO.File]::WriteAllText((Join-Path $slotPackageRoot 'package.json'),'{"name":"@anthropic-ai/claude-code","version":"2.1.1"}',(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $slotPackageRoot 'node_modules\@anthropic-ai\claude-code-win32-x64\package.json'),'{"name":"@anthropic-ai/claude-code-win32-x64","version":"2.1.1"}',(New-Object Text.UTF8Encoding($false)))
    }
    Invoke-ManagedHarnessTest 'unsupported cmd target and multiple launch lines are rejected' {
        $cmd = Join-Path $slot 'claude.cmd'
        Write-TestClaudeCmd $cmd '..\..\outside.exe'
        $rejected = $false; try { Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $harness -SlotId $slotId | Out-Null } catch { $rejected = $true }
        Assert-ManagedHarness $rejected 'Escaping command target was accepted.'
        Write-TestClaudeCmd $cmd 'node_modules\@anthropic-ai\claude-code\node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe'
        $text = [IO.File]::ReadAllText($cmd,[Text.Encoding]::ASCII) + "`r`n`"%dp0%\node_modules\@anthropic-ai\claude-code\bin\claude.exe`" %*`r`n"
        [IO.File]::WriteAllText($cmd,$text,(New-Object Text.ASCIIEncoding))
        $rejected = $false; try { Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $harness -SlotId $slotId | Out-Null } catch { $rejected = $true }
        Assert-ManagedHarness $rejected 'Multiple command targets were accepted.'
    }
    Write-TestClaudeCmd (Join-Path $slot 'claude.cmd') 'node_modules\@anthropic-ai\claude-code\node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe'

    $context = New-CcSwitchPortableContext -StickRoot $stick -SessionRoot $session -RuntimeRoot $runtime -ManagedHarnessRoot $harness -ManagedHarnessSlotId $slotId
    $null = Initialize-CcSwitchPortableContext -Context $context
    $environment = Get-CcSwitchPortableEnvironment -Context $context
    Invoke-ManagedHarnessTest 'opt-in PATH uses only the version slot, copied Node, and System32' {
        $expected = @($slot,(Join-Path $runtime 'node'),(Join-Path $env:SystemRoot 'System32')) -join ';'
        Assert-ManagedHarness ([string]::Equals([string]$environment.PATH,$expected,[StringComparison]::OrdinalIgnoreCase)) 'PATH contract differs.'
        Assert-ManagedHarness ([string]::Equals([string]$environment.npm_config_prefix,$slot,[StringComparison]::OrdinalIgnoreCase)) 'npm prefix differs from the managed slot.'
        Assert-ManagedHarness ([string]$environment.NODE_OPTIONS -ceq '--preserve-symlinks --preserve-symlinks-main') 'Managed Node options differ from the fixed lifecycle compatibility flags.'
    }
    Invoke-ManagedHarnessTest 'npm config and cache are isolated under owned staging, registry fixed' {
        $state = Join-Path $harness 'state\npm-data'
        foreach ($name in @('npm_config_cache','npm_config_userconfig','npm_config_globalconfig')) { Assert-ManagedHarness (Test-CcSwitchHarnessRuntimeWithin -Path ([string]$environment[$name]) -Root $state) ($name + ' escaped staging.') }
        Assert-ManagedHarness ([string]$environment.npm_config_registry -ceq 'https://registry.npmjs.org/') 'npm registry is not the official registry.'
        Assert-ManagedHarness ((Get-Item -LiteralPath $environment.npm_config_userconfig).Length -eq 0) 'User npmrc is not empty.'
        Assert-ManagedHarness ((Get-Item -LiteralPath $environment.npm_config_globalconfig).Length -eq 0) 'Global npmrc is not empty.'
    }
    Invoke-ManagedHarnessTest 'native update plan is declarative and anchored to managed slot' {
        $plan = Get-CcSwitchManagedClaudeUpdatePlan -StickRoot $stick -RuntimeRoot $runtime -ManagedHarnessRoot $harness -SlotId $slotId
        Assert-ManagedHarness (-not $plan.Executes -and -not $plan.WritesToRealUsb) 'Plan must not execute or write to USB.'
        Assert-ManagedHarness ([string]::Equals($plan.CliPath,(Join-Path $slot 'claude.cmd'),[StringComparison]::OrdinalIgnoreCase)) 'CLI plan is not anchored to managed slot.'
        Assert-ManagedHarness ($plan.Arguments -contains '@anthropic-ai/claude-code@latest') 'Plan did not target the official package.'
    }
    Invoke-ManagedHarnessTest 'fixture accepts exact managed paths' {
        $fixture = [ordered]@{Root=$root;Exe=(Join-Path $app 'cc-switch.exe');StickRoot=$stick;RuntimeRoot=$runtime;ManagedHarnessRoot=$harness;Environment=$environment;Arguments=@()}
        $path = Join-Path $root 'fixture.json'
        [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $fixture -Depth 5),(New-Object Text.UTF8Encoding($false)))
        $read = Read-AppContainerFixture -Path $path
        Assert-ManagedHarness ([IO.Path]::GetFullPath($read.ManagedHarnessRoot) -eq [IO.Path]::GetFullPath($harness)) 'ManagedHarnessRoot changed.'
    }
    Invoke-ManagedHarnessTest 'fixture rejects PATH injection and incomplete updater mailbox' {
        $fixture = [ordered]@{Root=$root;Exe=(Join-Path $app 'cc-switch.exe');StickRoot=$stick;RuntimeRoot=$runtime;ManagedHarnessRoot=$harness;Environment=$environment;Arguments=@()}
        $path = Join-Path $root 'fixture.json'
        $fixture.Environment['PATH'] = ($slot + ';' + (Join-Path $runtime 'node') + ';' + $env:APPDATA)
        [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $fixture -Depth 5),(New-Object Text.UTF8Encoding($false)))
        $rejected = $false; try { Read-AppContainerFixture -Path $path | Out-Null } catch { $rejected = $true }
        Assert-ManagedHarness $rejected 'An unapproved PATH entry was accepted.'
        $fixture.Environment = Get-CcSwitchPortableEnvironment -Context $context
        $fixture.Environment['CCSWITCH_PORTABLE_UPDATE_MAILBOX'] = Join-Path $runtime 'updates\portable-update.request'
        [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $fixture -Depth 5),(New-Object Text.UTF8Encoding($false)))
        $rejected = $false; try { Read-AppContainerFixture -Path $path | Out-Null } catch { $rejected = $true }
        Assert-ManagedHarness $rejected 'An incomplete updater mailbox/nonce pair was accepted.'
        $fixture.Environment['CCSWITCH_PORTABLE_UPDATE_NONCE'] = 'a' * 32
        [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $fixture -Depth 5),(New-Object Text.UTF8Encoding($false)))
        Read-AppContainerFixture -Path $path | Out-Null
        $fixture.Environment['CCSWITCH_PORTABLE_UPDATE_MAILBOX'] = Join-Path $runtime 'updates\elsewhere.request'
        [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $fixture -Depth 5),(New-Object Text.UTF8Encoding($false)))
        $rejected = $false; try { Read-AppContainerFixture -Path $path | Out-Null } catch { $rejected = $true }
        Assert-ManagedHarness $rejected 'An alternate updater mailbox path was accepted.'
    }
    Invoke-ManagedHarnessTest 'fixture accepts only fixed NODE_OPTIONS with the complete managed layout' {
        $fixture = [ordered]@{Root=$root;Exe=(Join-Path $app 'cc-switch.exe');StickRoot=$stick;RuntimeRoot=$runtime;ManagedHarnessRoot=$harness;Environment=(Get-CcSwitchPortableEnvironment -Context $context);Arguments=@()}
        $path = Join-Path $root 'fixture.json'
        [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $fixture -Depth 5),(New-Object Text.UTF8Encoding($false)))
        Read-AppContainerFixture -Path $path | Out-Null
        $fixture.Environment['NODE_OPTIONS'] = '--preserve-symlinks --require C:\\outside.js'
        [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $fixture -Depth 5),(New-Object Text.UTF8Encoding($false)))
        $rejected = $false; try { Read-AppContainerFixture -Path $path | Out-Null } catch { $rejected = $true }
        Assert-ManagedHarness $rejected 'A different Node option was accepted.'
        $fixture.Environment = [ordered]@{HOME=$stick;USERPROFILE=$session;APPDATA=(Join-Path $session 'AppData\\Roaming');LOCALAPPDATA=(Join-Path $session 'AppData\\Local');CC_SWITCH_TEST_HOME=$stick;TEMP=(Join-Path $session 'temp');TMP=(Join-Path $session 'temp');NODE_OPTIONS='--preserve-symlinks --preserve-symlinks-main'}
        [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $fixture -Depth 5),(New-Object Text.UTF8Encoding($false)))
        $rejected = $false; try { Read-AppContainerFixture -Path $path | Out-Null } catch { $rejected = $true }
        Assert-ManagedHarness $rejected 'NODE_OPTIONS was accepted without managed slot/runtime/npm paths.'
    }
    Invoke-ManagedHarnessTest 'public runtime seed is copied into owned staging and version slot commits verifiably' {
        $usb = Join-Path $root 'usb-fixture'
        $owned = Join-Path $root 'owned-fixture'
        $usbNode = Join-Path $usb 'runtime\node'
        $usbGlobal = Join-Path $usb 'npm-global'
        $usbPackage = Join-Path $usbGlobal 'node_modules\@anthropic-ai\claude-code'
        $usbPackageBin = Join-Path $usbPackage 'bin'
        foreach ($dir in @($usbNode,(Join-Path $usbNode 'node_modules\npm\bin'),$usbPackageBin)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
        [IO.File]::WriteAllText((Join-Path $usbNode 'node.exe'),'node fixture',(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $usbNode 'npm.cmd'),'@echo off',(New-Object Text.ASCIIEncoding))
        [IO.File]::WriteAllText((Join-Path $usbNode 'node_modules\npm\bin\npm-cli.js'),'npm fixture',(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $usbGlobal 'claude.cmd'),'@echo off',(New-Object Text.ASCIIEncoding))
        [IO.File]::WriteAllText((Join-Path $usbPackage 'package.json'),'{"name":"@anthropic-ai/claude-code","version":"2.1.1"}',(New-Object Text.UTF8Encoding($false)))
        [IO.Directory]::CreateDirectory((Join-Path $usbPackage 'node_modules\@anthropic-ai\claude-code-win32-x64')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $usbPackage 'node_modules\@anthropic-ai\claude-code-win32-x64\package.json'),'{"name":"@anthropic-ai/claude-code-win32-x64","version":"2.1.1"}',(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllBytes((Join-Path $usbPackageBin 'claude.exe'),(New-Object byte[] 128))
        [IO.File]::Copy($testExe,(Join-Path $usbPackage 'node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe'))
        Write-TestClaudeCmd (Join-Path $usbGlobal 'claude.cmd') 'node_modules\@anthropic-ai\claude-code\node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe'
        $sessionState = Initialize-CcManagedHarnessSession -UsbRoot $usb -OwnedRoot $owned -SlotId '2.1.1'
        Assert-ManagedHarness ($sessionState.Ready -and (Test-Path -LiteralPath (Join-Path $owned 'runtime\node\node.exe'))) 'Initial seed did not reach NTFS-owned staging.'
        $adapterPath = Join-Path $owned 'harness\slots\2.1.1\npm.cmd'
        $installerPath = Join-Path $owned 'runtime\updates\cc-switch-portable-claude-install.cjs'
        Assert-ManagedHarness ((Test-Path -LiteralPath $adapterPath -PathType Leaf) -and (Test-Path -LiteralPath $installerPath -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $owned 'harness\updates') -PathType Container)) 'Temporary sibling adapter or portable installer runtime directories were not staged.'
        Assert-ManagedHarness ((Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'cc-switch-portable-claude-install.cjs') -Algorithm SHA256).Hash) 'Portable installer staging copy does not match its source hash.'
        Assert-ManagedHarness ((Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot (Join-Path $owned 'harness') -SlotId '2.1.1').Valid) 'Exact temporary sibling adapter was not accepted by slot validation.'
        [IO.File]::WriteAllText($adapterPath,'@echo off`r`nrem altered`r`n',(New-Object Text.ASCIIEncoding))
        $badAdapterRejected = $false
        try { Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot (Join-Path $owned 'harness') -SlotId '2.1.1' | Out-Null } catch { $badAdapterRejected = $true }
        Assert-ManagedHarness $badAdapterRejected 'Modified sibling adapter was accepted.'
        [IO.File]::WriteAllText($adapterPath,(Get-CcSwitchManagedClaudeNpmAdapterText),(New-Object Text.ASCIIEncoding))
        [IO.File]::Delete($adapterPath)
        [IO.Directory]::CreateDirectory($adapterPath) | Out-Null
        $adapterDirectoryRejected = $false
        try { Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot (Join-Path $owned 'harness') -SlotId '2.1.1' | Out-Null } catch { $adapterDirectoryRejected = $true }
        Assert-ManagedHarness $adapterDirectoryRejected 'A directory named npm.cmd bypassed adapter validation.'
        Remove-Item -LiteralPath $adapterPath -Force
        [IO.File]::WriteAllText($adapterPath,(Get-CcSwitchManagedClaudeNpmAdapterText),(New-Object Text.ASCIIEncoding))
        $traversalRejected = $false
        try { Remove-CcSwitchManagedClaudeNpmAdapter -ManagedHarnessRoot (Join-Path $owned 'harness') -RuntimeRoot (Join-Path $owned 'runtime') -SlotId '..\outside' | Out-Null } catch { $traversalRejected = $true }
        Assert-ManagedHarness $traversalRejected 'Adapter cleanup accepted a traversal slot id.'
        $saveRejectedWithAdapter = $false
        try { Save-CcManagedClaudeVersionSlot -StagedSlotPath (Join-Path $owned 'harness\slots\2.1.1') -UsbRoot $usb -ExpectedVolume (Get-CcSwitchHarnessVolumeIdentity -Path $usb) | Out-Null } catch { $saveRejectedWithAdapter = $true }
        Assert-ManagedHarness $saveRejectedWithAdapter 'Save accepted a slot that still contains the temporary adapter.'
        $null = Remove-CcSwitchManagedClaudeNpmAdapter -ManagedHarnessRoot (Join-Path $owned 'harness') -RuntimeRoot (Join-Path $owned 'runtime') -SlotId '2.1.1'
        Assert-ManagedHarness (-not (Test-Path -LiteralPath $adapterPath)) 'Temporary adapter was not removed before persistence.'
        $expectedVolume=Get-CcSwitchHarnessVolumeIdentity -Path $usb
        $baselineForSave=Get-CcSwitchClaudeSaveBaseline -UsbRoot $usb
        Assert-ManagedHarness (Test-CcSwitchManagedClaudeTreesIdentical -Candidate (Join-Path $owned 'harness\slots\2.1.1') -Baseline $baselineForSave.Path) 'Unchanged staged package differs from the trusted USB baseline and would require online verification.'
        $saved = Save-CcManagedClaudeVersionSlot -StagedSlotPath (Join-Path $owned 'harness\slots\2.1.1') -UsbRoot $usb -ExpectedVolume $expectedVolume
        Assert-ManagedHarness ($saved.Saved -and $saved.Version -ceq '2.1.1') 'Validated slot was not committed to the public USB store.'
        $resolved = Resolve-CcManagedClaudeVersionSlot -UsbRoot $usb
        Assert-ManagedHarness ($resolved.SlotId -ceq '2.1.1' -and (Test-Path -LiteralPath (Join-Path $resolved.Path 'claude.cmd'))) 'Resolver did not return the committed version.'
        Assert-ManagedHarness (-not (Test-Path -LiteralPath (Join-Path $resolved.Path 'npm.cmd'))) 'Temporary npm adapter leaked into the persistent USB version slot.'
        $badUsb = Join-Path $root 'usb-invalid'
        [IO.Directory]::CreateDirectory($badUsb) | Out-Null
        $stagedPackage=Join-Path $owned 'harness\slots\2.1.1\node_modules\@anthropic-ai\claude-code\package.json'
        $stagedPlatform=Join-Path $owned 'harness\slots\2.1.1\node_modules\@anthropic-ai\claude-code\node_modules\@anthropic-ai\claude-code-win32-x64\package.json'
        [IO.File]::WriteAllText($stagedPackage,'{"name":"@anthropic-ai/claude-code","version":"2.1.2"}',(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($stagedPlatform,'{"name":"@anthropic-ai/claude-code-win32-x64","version":"2.1.2"}',(New-Object Text.UTF8Encoding($false)))
        $rejected = $false; try { Save-CcManagedClaudeVersionSlot -StagedSlotPath (Join-Path $owned 'harness\slots\2.1.1') -UsbRoot $badUsb -ExpectedVolume $expectedVolume | Out-Null } catch { $rejected = $true }
        Assert-ManagedHarness ($rejected -and -not (Test-Path -LiteralPath (Join-Path $badUsb 'tools'))) 'Invalid staged update wrote to USB before validation.'
        [IO.File]::WriteAllText($stagedPackage,'{"name":"@anthropic-ai/claude-code","version":"2.1.1"}',(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($stagedPlatform,'{"name":"@anthropic-ai/claude-code-win32-x64","version":"2.1.1"}',(New-Object Text.UTF8Encoding($false)))
        $collisionRejected = $false
        try { Save-CcManagedClaudeVersionSlot -StagedSlotPath (Join-Path $owned 'harness\slots\2.1.1') -UsbRoot $usb -ExpectedVolume $expectedVolume | Out-Null } catch { $collisionRejected = $true }
        Assert-ManagedHarness (-not $collisionRejected) 'Saving an identical verified immutable slot should be idempotent.'

        $legacyRecoveryUsb=Join-Path $root 'usb-legacy-recovery'
        $legacyRecoveryOwned=Join-Path $root 'owned-legacy-recovery'
        [IO.Directory]::CreateDirectory($legacyRecoveryUsb)|Out-Null
        Copy-CcSwitchManagedHarnessTree -Source (Join-Path $usb 'runtime\node') -Destination (Join-Path $legacyRecoveryUsb 'runtime\node')
        Copy-CcSwitchManagedHarnessTree -Source (Join-Path $usb 'npm-global') -Destination (Join-Path $legacyRecoveryUsb 'npm-global')
        $legacySlots=Join-Path $legacyRecoveryUsb 'tools\harness\claude\slots'
        [IO.Directory]::CreateDirectory((Join-Path $legacySlots '.incoming-abandoned\slots\9.9.9'))|Out-Null
        [IO.File]::WriteAllText((Join-Path $legacySlots '9.9.9.manifest.json'),'orphan sidecar without a published slot',(New-Object Text.UTF8Encoding($false)))
        $legacySession=Initialize-CcManagedHarnessSession -UsbRoot $legacyRecoveryUsb -OwnedRoot $legacyRecoveryOwned
        Assert-ManagedHarness ($legacySession.PackageVersion -ceq '2.1.1') 'Incoming-only slot tree or orphan sidecar prevented legacy npm-global initialization.'

        $updatedPackage=Join-Path $owned 'harness\slots\2.1.1\node_modules\@anthropic-ai\claude-code\package.json'
        $updatedPlatform=Join-Path $owned 'harness\slots\2.1.1\node_modules\@anthropic-ai\claude-code\node_modules\@anthropic-ai\claude-code-win32-x64\package.json'
        $updatedExe=Join-Path $owned 'harness\slots\2.1.1\node_modules\@anthropic-ai\claude-code\node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe'
        [IO.File]::WriteAllText($updatedPackage,'{"name":"@anthropic-ai/claude-code","version":"2.1.2"}',(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($updatedPlatform,'{"name":"@anthropic-ai/claude-code-win32-x64","version":"2.1.2"}',(New-Object Text.UTF8Encoding($false)))
        [IO.File]::Copy($testExeNew,$updatedExe,$true)
        $global:CcSwitchManagedSaveVerifierCalls=0
        $realVerifierFunction=(Get-Command Invoke-CcSwitchPortableClaudeSaveVerifier -CommandType Function).ScriptBlock
        $mockVerifier={param([string]$UsbRoot,[string]$OwnedRuntimeRoot,[string]$Candidate,[string]$Baseline,[string]$ExpectedVersion,$ExpectedVolume)$global:CcSwitchManagedSaveVerifierCalls++;$global:CcSwitchManagedSaveVerifierCandidate=$Candidate;$global:CcSwitchManagedSaveVerifierBaseline=$Baseline;return [pscustomobject]@{Verified=$true;Version=$ExpectedVersion;Output=('Claude Code '+$ExpectedVersion+' verified for save.')}}
        Set-Item -LiteralPath Function:\Invoke-CcSwitchPortableClaudeSaveVerifier -Value $mockVerifier
        $realManifestWriter=(Get-Command Write-CcSwitchManagedClaudeHashManifest -CommandType Function).ScriptBlock
        Set-Item -LiteralPath Function:\Write-CcSwitchManagedClaudeHashManifest -Value { throw 'injected manifest write failure' }
        $manifestFailureRejected=$false
        $manifestFailureMessage=''
        try { Save-CcManagedClaudeVersionSlot -StagedSlotPath (Join-Path $owned 'harness\slots\2.1.1') -UsbRoot $usb -ExpectedVolume $expectedVolume -AllowOnlineVerification | Out-Null } catch { $manifestFailureMessage=$_.Exception.Message; $manifestFailureRejected=$manifestFailureMessage -like '*manifest write failure*' }
        Set-Item -LiteralPath Function:\Write-CcSwitchManagedClaudeHashManifest -Value $realManifestWriter
        Assert-ManagedHarness ($manifestFailureRejected -and $global:CcSwitchManagedSaveVerifierCalls -eq 1) 'Manifest-write fault did not fail after independent verification.'
        Assert-ManagedHarness (-not (Test-Path -LiteralPath (Join-Path $usb 'tools\harness\claude\slots\2.1.2')) -and -not (Test-Path -LiteralPath (Join-Path $usb 'tools\harness\claude\slots\2.1.2.manifest.json'))) 'Manifest-write failure published a partial version slot or sidecar.'
        Assert-ManagedHarness (@(Get-ChildItem -LiteralPath (Join-Path $usb 'tools\harness\claude\slots') -Directory -Filter '.incoming-*' -Force).Count -eq 0) 'Manifest-write failure did not clean its incoming workspace on the unchanged volume.'

        $newSidecar=Join-Path $usb 'tools\harness\claude\slots\2.1.2.manifest.json'
        $orphanStage=Join-Path $owned 'harness\slots\2.1.2'
        [IO.Directory]::CreateDirectory($orphanStage)|Out-Null
        Copy-CcSwitchManagedHarnessTree -Source (Join-Path $owned 'harness\slots\2.1.1') -Destination $orphanStage
        Write-CcSwitchManagedClaudeHashManifest -SlotPath $orphanStage -ManifestPath $newSidecar -Version '2.1.2'
        Assert-ManagedHarness (-not (Test-Path -LiteralPath (Join-Path $usb 'tools\harness\claude\slots\2.1.2'))) 'Orphan-sidecar fixture already has a published version directory.'
        $retried=Save-CcManagedClaudeVersionSlot -StagedSlotPath (Join-Path $owned 'harness\slots\2.1.1') -UsbRoot $usb -ExpectedVolume $expectedVolume -AllowOnlineVerification
        Assert-ManagedHarness ($retried.Saved -and $retried.Version -ceq '2.1.2' -and $global:CcSwitchManagedSaveVerifierCalls -eq 2) 'Retry did not reuse and verify an orphan sidecar before publishing the directory.'
        Assert-ManagedHarness ((Resolve-CcManagedClaudeVersionSlot -UsbRoot $usb).Version -ceq '2.1.2') 'Complete version directory plus sidecar was not recoverable by the resolver.'
        Set-Item -LiteralPath Function:\Invoke-CcSwitchPortableClaudeSaveVerifier -Value $realVerifierFunction
        Remove-Variable CcSwitchManagedSaveVerifierCalls,CcSwitchManagedSaveVerifierCandidate,CcSwitchManagedSaveVerifierBaseline -Scope Global -ErrorAction SilentlyContinue
    }
} finally {
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if ((Split-Path -Parent ([IO.Path]::GetFullPath($root))).TrimEnd('\','/') -ine $temp -or (Split-Path -Leaf $root) -cne ('aistick-ac-probe-' + $guidText)) { throw 'Refusing cleanup outside the unique synthetic fixture boundary.' }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
}
Write-Host ("Managed Claude harness checks: {0} passed, {1} failed." -f $script:passed,$script:failed)
if ($script:failed) { exit 1 }
