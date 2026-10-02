# Synthetic-only integration checks for the Windows PowerShell 5.1 named-pipe helpers.
[CmdletBinding()]param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 5){throw 'Run this test with Windows PowerShell 5.1.'}
. (Join-Path $PSScriptRoot 'cc-switch-secure-session.ps1')

$script:TestPipeName='AiStick.CcSwitch.Session.Synthetic.'+[guid]::NewGuid().ToString('N').Substring(0,16)
$script:TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('cc-ipc-root-'+[guid]::NewGuid().ToString('N'))
$script:TestLocalAppData=Join-Path $script:TestRoot 'local-app-data'
$script:TestLocator=Join-Path $script:TestLocalAppData 'AiStick\SecureSessions\synthetic.json'
$script:OriginalLocalAppData=$env:LOCALAPPDATA
$script:SecureSessionScript=Join-Path $PSScriptRoot 'cc-switch-secure-session.ps1'
$script:SecureManagerWindowScript=Join-Path $PSScriptRoot 'cc-switch-secure-manager-window.ps1'
$script:MockCommandLine='powershell.exe -File "'+$script:SecureSessionScript+'" -StickRoot "'+$script:TestRoot+'"'
$script:MockProcessMissing=$false
$script:MockCommandLineUnavailable=$false
$script:Pass=0
$script:Fail=0

function Get-CcSecurePipeName([string]$Root){return $script:TestPipeName}
function Get-CcSecureLocatorPath([string]$PipeName){return $script:TestLocator}
function Test-CcSecureSessionPipeAvailable([string]$StickRoot,[string]$PipeName){return [bool]$script:MockSecurePipeAvailable}
function Get-CimInstance {
    [CmdletBinding()]
    param([Parameter(Position=0)][string]$ClassName,[string]$Filter)
    if($script:MockProcessMissing){return $null}
    if($script:MockCommandLineUnavailable){return [pscustomobject]@{ProcessId=$PID}}
    return [pscustomobject]@{ProcessId=$PID;CommandLine=$script:MockCommandLine}
}
function Assert-Ipc([string]$Name,[bool]$Condition){
    if($Condition){$script:Pass++;Write-Host ('PASS '+$Name) -ForegroundColor Green}
    else{$script:Fail++;Write-Host ('FAIL '+$Name) -ForegroundColor Red}
}
function Test-IpcHostCommandFromShadowedScope([string]$CommandLine,[string]$Root){
    $scriptDir='C:\synthetic-wrong-caller-scope'
    return Test-CcSecureHostCommandLine -CommandLine $CommandLine -Root $Root
}
function New-IpcLocator {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $script:TestLocator))
    $process=Get-Process -Id $PID
    $record=[ordered]@{
        Version=1
        Root=[IO.Path]::GetFullPath($script:TestRoot).TrimEnd('\')
        PipeName=$script:TestPipeName
        ProcessId=$PID
        StartTimeUtcTicks=$process.StartTime.ToUniversalTime().Ticks
    }
    [IO.File]::WriteAllText($script:TestLocator,(ConvertTo-Json $record -Compress),(New-Object Text.UTF8Encoding($false)))
    $acl=New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),(New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))) {
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','None','None','Allow')
        [void]$acl.AddAccessRule($rule)
    }
    [IO.File]::SetAccessControl($script:TestLocator,$acl)
}
function Set-IpcProtectedLocatorAcl {
    $acl=New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),(New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))) {
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','None','None','Allow')
        [void]$acl.AddAccessRule($rule)
    }
    [IO.File]::SetAccessControl($script:TestLocator,$acl)
}
function New-IpcPipeSecurity {
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $security=New-Object IO.Pipes.PipeSecurity
    $rule=New-Object IO.Pipes.PipeAccessRule($sid,[IO.Pipes.PipeAccessRights]::ReadWrite,[Security.AccessControl.AccessControlType]::Allow)
    $security.AddAccessRule($rule)
    $security.SetAccessRuleProtection($true,$false)
    return $security
}
function Start-IpcSyntheticServer([string]$Mode) {
    $initial=[Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $runspace=[RunspaceFactory]::CreateRunspace($initial)
    $runspace.Open()
    $worker=[PowerShell]::Create()
    $worker.Runspace=$runspace
    $scriptBlock={
        param($ModulePath,$PipeName,$ServerMode,$RootPath)
        . $ModulePath
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $security=New-Object IO.Pipes.PipeSecurity
        $security.AddAccessRule((New-Object IO.Pipes.PipeAccessRule($sid,[IO.Pipes.PipeAccessRights]::ReadWrite,[Security.AccessControl.AccessControlType]::Allow)))
        $security.SetAccessRuleProtection($true,$false)
        $server=New-CcSecureServerPipe -Name $PipeName -Security $security -First $true
        try {
            $server.WaitForConnection()
            $requestLine=Read-CcSecurePipeLine -Stream $server -TimeoutMilliseconds 5000 -MaxBytes 4096
            if(-not $requestLine){throw 'Synthetic server received an empty request.'}
            $requestObject=$requestLine|ConvertFrom-Json -ErrorAction Stop
            if($ServerMode -eq 'Timeout') {Start-Sleep -Milliseconds 6500;return 'TIMEOUT_SERVER_DONE'}
            $hostPid=$PID
            if($ServerMode -eq 'WrongReplyPid'){$hostPid=$PID+1000}
            if($ServerMode -eq 'LargeLaunchFiles') {
                $content='配置🎛️'+('synthetic-content-'*15000)
                $encoded=[Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($content))
                $bundle=[ordered]@{Revision='synthetic-revision';Provider=[ordered]@{Name='Synthetic Provider';BaseUrl='https://synthetic.invalid/v1';Models=[ordered]@{ANTHROPIC_MODEL='fixture'};AuthEnvironmentName='ANTHROPIC_AUTH_TOKEN';Secret='synthetic-secret'};LaunchFiles=@([ordered]@{Path='CLAUDE.md';ContentBase64=$encoded})}
                $body=ConvertTo-Json -Compress -Depth 12 -InputObject ([ordered]@{Ok=$true;HostPid=$hostPid;LaunchBundle=$bundle})
                Write-CcSecurePipeLine -Stream $server -Text $body -TimeoutMilliseconds 30000
            } else {
                $body=ConvertTo-Json -Compress -InputObject ([ordered]@{Ok=$true;HostPid=$hostPid;Unlocked=$true;ProviderName='Synthetic Provider'})
                Write-CcSecurePipeLine -Stream $server -Text $body -TimeoutMilliseconds 5000
            }
            return ('SERVED '+$requestObject.Action)
        } catch {Write-Error -ErrorRecord $_;throw} finally {$server.Dispose()}
    }
    $null=$worker.AddScript($scriptBlock).AddArgument((Join-Path $PSScriptRoot 'cc-switch-secure-session.ps1')).AddArgument($script:TestPipeName).AddArgument($Mode).AddArgument($script:TestRoot)
    $handle=$worker.BeginInvoke()
    return [pscustomobject]@{PowerShell=$worker;Runspace=$runspace;Handle=$handle}
}
function Stop-IpcServer($Server,[int]$WaitMilliseconds=10000){
    if(-not $Server){return $null}
    try {
        if(-not $Server.Handle.AsyncWaitHandle.WaitOne($WaitMilliseconds)){$Server.PowerShell.Stop();throw 'Synthetic pipe server did not exit before deadline.'}
        $result=@($Server.PowerShell.EndInvoke($Server.Handle))
        if($Server.PowerShell.Streams.Error.Count){throw [string]$Server.PowerShell.Streams.Error[0]}
        return ($result -join '')
    } finally {$Server.PowerShell.Dispose();$Server.Runspace.Dispose()}
}

$active=$null
try {
    [void][IO.Directory]::CreateDirectory($script:TestRoot)
    [void][IO.Directory]::CreateDirectory($script:TestLocalAppData)
    $env:LOCALAPPDATA=$script:TestLocalAppData
    $sessionCommand='powershell.exe -NoProfile -File "'+$script:SecureSessionScript+'" -StickRoot "'+$script:TestRoot+'"'
    $wrapperCommand='powershell.exe -NoProfile -File "'+$script:SecureManagerWindowScript+'" -StickRoot "'+$script:TestRoot+'"'
    $sameNameOtherDirectory='powershell.exe -NoProfile -File "'+(Join-Path $script:TestRoot 'cc-switch-secure-manager-window.ps1')+'" -StickRoot "'+$script:TestRoot+'"'
    $mentionOnly='powershell.exe -Command "Write-Host cc-switch-secure-manager-window.ps1 '+$script:TestRoot+'"'
    $wrongRootCommand='powershell.exe -NoProfile -File "'+$script:SecureManagerWindowScript+'" -StickRoot "'+(Join-Path $script:TestRoot 'different-root')+'"'
    Assert-Ipc 'authenticates the direct secure-session -File entrypoint for the exact root' (Test-CcSecureHostCommandLine $sessionCommand $script:TestRoot)
    Assert-Ipc 'authenticates the secure-manager-window -File entrypoint for the exact root' (Test-CcSecureHostCommandLine $wrapperCommand $script:TestRoot)
    Assert-Ipc 'entrypoint path is stable when a caller function shadows scriptDir' (Test-IpcHostCommandFromShadowedScope $wrapperCommand $script:TestRoot)
    Assert-Ipc 'rejects an otherwise valid script command using another root' (-not (Test-CcSecureHostCommandLine $wrongRootCommand $script:TestRoot))
    Assert-Ipc 'rejects same-name script outside the official scripts directory' (-not (Test-CcSecureHostCommandLine $sameNameOtherDirectory $script:TestRoot))
    Assert-Ipc 'rejects command lines that only mention an official script path' (-not (Test-CcSecureHostCommandLine $mentionOnly $script:TestRoot))
    Assert-Ipc 'manager starts the existing unlock host only when no live pipe exists' ((Get-CcSecureManagerSessionDisposition -PipeAvailable $false -LocatorAvailable $false) -eq 'Start')
    Assert-Ipc 'manager treats a dead pipe with stale locator as an unlock-host start' ((Get-CcSecureManagerSessionDisposition -PipeAvailable $false -LocatorAvailable $true) -eq 'Start')
    Assert-Ipc 'manager reuses only a live pipe with a locator' ((Get-CcSecureManagerSessionDisposition -PipeAvailable $true -LocatorAvailable $true) -eq 'Reuse')
    Assert-Ipc 'manager fails closed on live pipe without locator' ((Get-CcSecureManagerSessionDisposition -PipeAvailable $true -LocatorAvailable $false) -eq 'FailClosed')
    Assert-Ipc 'successful Lock reply without optional NoSession field is not treated as no-session under StrictMode' (-not (Test-CcSecureSessionNoSessionResult ([pscustomobject]@{Ok=$true;Locked=$true})))
    Assert-Ipc 'no-session Lock result is recognized when explicitly marked' (Test-CcSecureSessionNoSessionResult ([pscustomobject]@{NoSession=$true;Locked=$false}))
    Write-Host 'RUN idempotent Lock without a session'
    $script:MockSecurePipeAvailable=$false
    $noSessionLock=Lock-CcSecureSession -StickRoot $script:TestRoot
    Assert-Ipc 'Lock with no locator and no live pipe is a benign no-op' ($noSessionLock.NoSession -and -not $noSessionLock.Locked)
    New-IpcLocator
    $staleRecord=[IO.File]::ReadAllText($script:TestLocator,[Text.Encoding]::UTF8)|ConvertFrom-Json
    $staleRecord.ProcessId=2147483000
    [IO.File]::WriteAllText($script:TestLocator,(ConvertTo-Json $staleRecord -Compress),(New-Object Text.UTF8Encoding($false)))
    Set-IpcProtectedLocatorAcl
    $staleLock=Lock-CcSecureSession -StickRoot $script:TestRoot
    Assert-Ipc 'Lock with a stale locator is a benign no-op and preserves locator for safe host recovery' ($staleLock.NoSession -and $staleLock.StaleLocator -and [IO.File]::Exists($script:TestLocator))
    $wrongRootRecord=[IO.File]::ReadAllText($script:TestLocator,[Text.Encoding]::UTF8)|ConvertFrom-Json
    $wrongRootRecord.Root=Join-Path $script:TestRoot 'different-root'
    [IO.File]::WriteAllText($script:TestLocator,(ConvertTo-Json $wrongRootRecord -Compress),(New-Object Text.UTF8Encoding($false)))
    Set-IpcProtectedLocatorAcl
    $wrongRootRejected=$false
    try {Assert-CcSecureSessionStaleLocator -StickRoot $script:TestRoot -PipeName $script:TestPipeName -LocatorPath $script:TestLocator|Out-Null} catch {$wrongRootRejected=$_.Exception.Message -like '*does not match this volume root*'}
    Assert-Ipc 'stale locator with mismatched root is never accepted as a new session' $wrongRootRejected
    New-IpcLocator
    $badLocatorAcl=New-Object Security.AccessControl.FileSecurity
    $badLocatorAcl.SetAccessRuleProtection($false,$true)
    [IO.File]::SetAccessControl($script:TestLocator,$badLocatorAcl)
    $badStaleAclRejected=$false
    try {Assert-CcSecureSessionStaleLocator -StickRoot $script:TestRoot -PipeName $script:TestPipeName -LocatorPath $script:TestLocator|Out-Null} catch {$badStaleAclRejected=$_.Exception.Message -like '*ACL is inheritable*'}
    Assert-Ipc 'stale locator with unsafe ACL is not treated as absent' $badStaleAclRejected
    [IO.File]::Delete($script:TestLocator)
    $script:MockSecurePipeAvailable=$true
    $missingLocatorRejected=$false
    try {$null=Lock-CcSecureSession -StickRoot $script:TestRoot} catch {$missingLocatorRejected=$_.Exception.Message -like '*定位文件缺失*'}
    Assert-Ipc 'Lock refuses to treat a live pipe without locator as a locked session' $missingLocatorRejected
    $script:MockSecurePipeAvailable=$false
    New-IpcLocator

    Write-Host 'RUN IPC status exchange'
    $active=Start-IpcSyntheticServer 'Reply'
    try {$reply=Send-CcSecureSessionRequest -Root $script:TestRoot -Action Status}
    catch {$clientError=$_.Exception.Message;try{$serverInfo=Stop-IpcServer $active}catch{$serverInfo=$_.Exception.Message};throw ('IPC client failed: '+$clientError+'; server: '+$serverInfo)}
    Assert-Ipc 'actual pipe client/server exchange returns synthetic status' ($reply.Ok -and $reply.HostPid -eq $PID -and $reply.ProviderName -eq 'Synthetic Provider')
    Assert-Ipc 'server handled expected request' ((Stop-IpcServer $active) -eq 'SERVED Status')
    $active=$null

    Write-Host 'RUN large UTF-8 Claude launch bundle response'
    $active=Start-IpcSyntheticServer 'LargeLaunchFiles'
    $bundleReply=Send-CcSecureSessionRequest -Root $script:TestRoot -Action GetClaudeLaunchFiles
    $encodedFile=[string]$bundleReply.LaunchBundle.LaunchFiles[0].ContentBase64
    $bundleText=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedFile))
    Assert-Ipc 'broker accepts a launch bundle response larger than the ordinary 64 KiB limit' ($encodedFile.Length -gt 65536 -and $bundleReply.LaunchBundle.Revision -eq 'synthetic-revision')
    Assert-Ipc 'large response preserves UTF-8 paths and content and converts provider secret' ($bundleReply.LaunchBundle.LaunchFiles[0].Path -eq 'CLAUDE.md' -and $bundleText.StartsWith('配置🎛️') -and $bundleReply.LaunchBundle.Provider.Secret -is [Security.SecureString])
    $bundleReply.LaunchBundle.Provider.Secret.Dispose()
    Assert-Ipc 'server handled launch bundle request' ((Stop-IpcServer $active) -eq 'SERVED GetClaudeLaunchFiles')
    $active=$null

    Write-Host 'RUN duplicate server instance check'
    $pipeSecurity=New-IpcPipeSecurity
    $first=New-CcSecureServerPipe -Name $script:TestPipeName -Security $pipeSecurity -First $true
    $duplicateRejected=$false
    try {$duplicate=New-CcSecureServerPipe -Name $script:TestPipeName -Security $pipeSecurity -First $true;$duplicate.Dispose()}
    catch {$duplicateRejected=$true}
    finally {$first.Dispose()}
    Assert-Ipc 'simultaneous first-instance server startup is rejected' $duplicateRejected

    Write-Host 'RUN stale locator check'
    $script:MockCommandLine='unrelated-process.exe'
    $mockProcess=Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
    Assert-Ipc 'test supplies unrelated process command line to client locator check' ($mockProcess.CommandLine -eq 'unrelated-process.exe')
    $staleRejected=$false;$staleMessage=''
    try {$null=Send-CcSecureSessionRequest -Root $script:TestRoot -Action Status} catch {$staleMessage=$_.Exception.Message;$staleRejected=$staleMessage -like '*does not match the protected locator*'}
    if(-not $staleRejected){Write-Host ('Stale locator rejection was: '+$staleMessage)}
    Assert-Ipc 'stale or unrelated locator process is rejected before pipe connect' $staleRejected
    $script:MockCommandLine='powershell.exe -File "'+$script:SecureSessionScript+'" -StickRoot "'+$script:TestRoot+'"'

    $script:MockProcessMissing=$true;$missingProcessMessage=''
    try {$null=Send-CcSecureSessionRequest -Root $script:TestRoot -Action Status} catch {$missingProcessMessage=$_.Exception.Message}
    Assert-Ipc 'missing host process has a distinct safe locator error' ($missingProcessMessage -like '*process from the protected locator is missing*')
    $script:MockProcessMissing=$false;$script:MockCommandLineUnavailable=$true;$missingCommandLineMessage=''
    try {$null=Send-CcSecureSessionRequest -Root $script:TestRoot -Action Status} catch {$missingCommandLineMessage=$_.Exception.Message}
    Assert-Ipc 'unavailable host command line has a distinct safe error' ($missingCommandLineMessage -like '*command line is unavailable*')
    $script:MockCommandLineUnavailable=$false

    Write-Host 'RUN oversized locator check'
    New-IpcLocator
    $largeLocator=[IO.File]::ReadAllText($script:TestLocator,[Text.Encoding]::UTF8)|ConvertFrom-Json
    $largeLocator|Add-Member -NotePropertyName Padding -NotePropertyValue ('x'*5000) -Force
    [IO.File]::WriteAllText($script:TestLocator,(ConvertTo-Json $largeLocator -Compress),(New-Object Text.UTF8Encoding($false)))
    Set-IpcProtectedLocatorAcl
    $oversizeRejected=$false
    try {$null=Send-CcSecureSessionRequest -Root $script:TestRoot -Action Status} catch {$oversizeRejected=$_.Exception.Message -like '*fixed size limit*'}
    Assert-Ipc 'oversized locator is rejected before pipe connect' $oversizeRejected

    Write-Host 'RUN locator ACL check'
    New-IpcLocator
    $unprotected=New-Object Security.AccessControl.FileSecurity
    $unprotected.SetAccessRuleProtection($false,$true)
    [IO.File]::SetAccessControl($script:TestLocator,$unprotected)
    $aclRejected=$false
    try {$null=Send-CcSecureSessionRequest -Root $script:TestRoot -Action Status} catch {$aclRejected=$_.Exception.Message -like '*ACL is inheritable*'}
    Assert-Ipc 'inheritable locator ACL is rejected before pipe connect' $aclRejected
    New-IpcLocator

    Write-Host 'RUN reply PID check'
    $active=Start-IpcSyntheticServer 'WrongReplyPid'
    $pidMismatch=$false
    try {$null=Send-CcSecureSessionRequest -Root $script:TestRoot -Action Status} catch {$pidMismatch=$_.Exception.Message -like '*did not match its protected locator*'}
    Assert-Ipc 'reply host PID mismatch is rejected' $pidMismatch
    $null=Stop-IpcServer $active
    $active=$null

    Write-Host 'RUN timeout check'
    $active=Start-IpcSyntheticServer 'Timeout'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $timedOut=$false
    try {$null=Send-CcSecureSessionRequest -Root $script:TestRoot -Action Status} catch {$timedOut=$_.Exception.Message -like '*deadline exceeded*'}
    $watch.Stop()
    Assert-Ipc 'unresponsive server triggers bounded client timeout' ($timedOut -and $watch.Elapsed.TotalSeconds -lt 6.5)
    Assert-Ipc 'server exits after timed-out client disconnects' ((Stop-IpcServer $active 5000) -eq 'TIMEOUT_SERVER_DONE')
    $active=$null
} finally {
    if($active){try{$active.PowerShell.Stop();$active.PowerShell.Dispose();$active.Runspace.Dispose()}catch{}}
    if([IO.File]::Exists($script:TestLocator)){[IO.File]::Delete($script:TestLocator)}
    if([IO.Directory]::Exists($script:TestRoot)){Remove-Item -LiteralPath $script:TestRoot -Recurse -Force}
    $env:LOCALAPPDATA=$script:OriginalLocalAppData
}
Write-Host ('Named-pipe IPC integration checks: '+$script:Pass+' passed, '+$script:Fail+' failed')
if($script:Fail){[Environment]::Exit(1)}
[Environment]::Exit(0)
