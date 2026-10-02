[CmdletBinding()]
param(
    [string]$StickRoot,
    [switch]$Client,
    [ValidateSet('Status','GetClaudeProvider','GetClaudeLaunchFiles','LaunchGui','Lock')][string]$Request='Status',
    [ValidateSet('None','InternetClient')][string]$NetworkMode='None',
    [switch]$ImportToolboxBeforeLaunch
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -and $MyInvocation.InvocationName -ne '.') { throw 'Requires Windows PowerShell 5.1.' }
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
if (-not ('CcSecurePipeNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class CcSecurePipeNative {
 [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public int bInheritHandle; }
 [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern SafePipeHandle CreateNamedPipe(string name,uint openMode,uint pipeMode,uint maxInstances,uint outSize,uint inSize,uint defaultTimeout,ref SECURITY_ATTRIBUTES securityAttributes);
 [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string sddl,uint revision,out IntPtr descriptor,out uint size);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
 [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetNamedPipeServerProcessId(IntPtr pipe, out uint serverProcessId);
 public static SafePipeHandle CreateFirstInstance(string name,string sddl,bool first) {
  IntPtr descriptor; uint size; if(!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl,1,out descriptor,out size)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
  try { SECURITY_ATTRIBUTES sa=new SECURITY_ATTRIBUTES();sa.nLength=Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));sa.lpSecurityDescriptor=descriptor;sa.bInheritHandle=0;
   uint flags=0x00000003u|0x40000000u|(first?0x00080000u:0u); SafePipeHandle h=CreateNamedPipe(name,flags,0,1,65536,4096,0,ref sa);if(h.IsInvalid)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());return h;
  } finally { LocalFree(descriptor); }
 }
}
'@
}
$scriptDir=$PSScriptRoot
. (Join-Path $scriptDir 'lib.ps1')
Set-ConsoleUtf8
if (-not $StickRoot) { $StickRoot=[IO.Path]::GetFullPath((Join-Path $scriptDir '..')) }
$StickRoot=[IO.Path]::GetFullPath($StickRoot)

function Get-CcSecurePipeName([string]$Root) {
    $volume=Get-VolumeIdentity -StickRoot $Root
    $identity=(([string]$volume.VolumeGuid)+'|'+[string]$volume.Serial+'|'+[IO.Path]::GetFullPath($Root).TrimEnd('\')).ToUpperInvariant()
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))).Replace('-','').Substring(0,24).ToLowerInvariant() }
    finally { $sha.Dispose() }
    return 'AiStick.CcSwitch.Session.'+$hash
}
function Get-CcSecureLocatorPath([string]$PipeName) { Join-Path (Join-Path $env:LOCALAPPDATA 'AiStick\SecureSessions') ($PipeName.Substring($PipeName.LastIndexOf('.')+1)+'.json') }
function Read-CcSecurePipeLine([IO.Stream]$Stream,[int]$TimeoutMilliseconds=5000,[int]$MaxBytes=65536) {
    $watch=[Diagnostics.Stopwatch]::StartNew();$memory=New-Object IO.MemoryStream;$buffer=New-Object byte[] 4096
    try {
        while($memory.Length -lt $MaxBytes){
            $left=$TimeoutMilliseconds-[int]$watch.ElapsedMilliseconds
            if($left -le 0){$Stream.Dispose();throw 'Secure pipe request deadline exceeded.'}
            $wanted=[Math]::Min($buffer.Length,$MaxBytes-[int]$memory.Length)
            $async=$Stream.BeginRead($buffer,0,$wanted,$null,$null)
            try{if(-not $async.AsyncWaitHandle.WaitOne($left)){$Stream.Dispose();throw 'Secure pipe request deadline exceeded.'};$count=$Stream.EndRead($async)}finally{$async.AsyncWaitHandle.Dispose()}
            if($count -le 0){return $null}
            $newline=[Array]::IndexOf($buffer,[byte]10,0,$count)
            if($newline -ge 0){$memory.Write($buffer,0,$newline);return (New-Object Text.UTF8Encoding($false,$true)).GetString($memory.ToArray()).TrimEnd("`r")}
            $memory.Write($buffer,0,$count)
        }
        throw 'Secure pipe message exceeds the fixed limit.'
    } finally { [Array]::Clear($buffer,0,$buffer.Length);$memory.Dispose() }
}
function Write-CcSecurePipeLine([IO.Stream]$Stream,[string]$Text,[int]$TimeoutMilliseconds=5000) {
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($Text+"`n");$async=$Stream.BeginWrite($bytes,0,$bytes.Length,$null,$null)
    try{if(-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)){throw 'Secure pipe response deadline exceeded.'};$Stream.EndWrite($async);$Stream.Flush()}finally{$async.AsyncWaitHandle.Dispose()}
}
function New-CcSecureServerPipe([string]$Name,[IO.Pipes.PipeSecurity]$Security,[bool]$First) {
    $sddl=$Security.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
    $handle=[CcSecurePipeNative]::CreateFirstInstance(('\\.\pipe\'+$Name),$sddl,$First)
    return New-Object IO.Pipes.NamedPipeServerStream([IO.Pipes.PipeDirection]::InOut,$true,$false,$handle)
}
function Test-CcSecureHostCommandLine([string]$CommandLine,[string]$Root) {
    if(-not $CommandLine -or -not $Root){return $false}
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    $rootPattern=[regex]::Escape($rootFull)+'(?:\\)?'
    if($rootFull -match '\s'){$rootArg='(?i)(?:^|\s)-StickRoot\s+"'+$rootPattern+'"(?=\s|$)'}
    else{$rootArg='(?i)(?:^|\s)-StickRoot\s+(?:"'+$rootPattern+'"|'+$rootPattern+'(?=\s|$))'}
    if($CommandLine -notmatch $rootArg){return $false}
    foreach($scriptName in @('cc-switch-secure-session.ps1','cc-switch-secure-manager-window.ps1')) {
        $scriptPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $scriptName))
        $scriptPattern=[regex]::Escape($scriptPath)
        if($scriptPath -match '\s'){$fileArg='(?i)(?:^|\s)-File\s+"'+$scriptPattern+'"(?=\s|$)'}
        else{$fileArg='(?i)(?:^|\s)-File\s+(?:"'+$scriptPattern+'"|'+$scriptPattern+'(?=\s|$))'}
        if($CommandLine -match $fileArg){return $true}
    }
    return $false
}
function ConvertTo-CcSecureHashtable($Value) {
    if($null -eq $Value){return $null}
    if($Value -is [System.Collections.IDictionary]){$map=@{};foreach($key in $Value.Keys){$map[[string]$key]=ConvertTo-CcSecureHashtable $Value[$key]};return $map}
    if($Value -is [pscustomobject]){$map=@{};foreach($property in $Value.PSObject.Properties){$map[[string]$property.Name]=ConvertTo-CcSecureHashtable $property.Value};return $map}
    if($Value -is [System.Array]){return ,@($Value|ForEach-Object {ConvertTo-CcSecureHashtable $_})}
    return $Value
}
function Send-CcSecureSessionRequest([string]$Root,[string]$Action) {
    if ($Action -notin @('Status','GetClaudeProvider','GetClaudeLaunchFiles','LaunchGui','Lock')) { throw 'Unsupported broker operation.' }
    $pipeName=Get-CcSecurePipeName $Root
    $locatorPath=Get-CcSecureLocatorPath $pipeName
    if(-not [IO.File]::Exists($locatorPath)){throw 'No secure session locator is registered for this volume root.'}
    $locatorDir=[IO.Path]::GetDirectoryName($locatorPath)
    foreach($candidate in @($env:LOCALAPPDATA,(Join-Path $env:LOCALAPPDATA 'AiStick'),$locatorDir,$locatorPath)){
        if(-not $candidate -or -not (Test-Path -LiteralPath $candidate)){throw 'Secure session locator path is missing.'}
        if((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Secure session locator path contains a reparse point.'}
    }
    $locatorItem=Get-Item -LiteralPath $locatorPath -Force
    if($locatorItem.Length -gt 4096){throw 'Secure session locator exceeds the fixed size limit.'}
    $locatorAcl=[IO.File]::GetAccessControl($locatorPath)
    if(-not $locatorAcl.AreAccessRulesProtected){throw 'Secure session locator ACL is inheritable.'}
    $allowed=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')
    foreach($rule in $locatorAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed){throw 'Secure session locator ACL grants access to an unexpected identity.'}
    }
    $locator=[IO.File]::ReadAllText($locatorPath,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    if([string]$locator.Root -cne $rootFull -or [string]$locator.PipeName -cne $pipeName){throw 'Secure session locator does not match this volume root.'}
    $locatorProcess=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$locator.ProcessId)" -ErrorAction Stop
    if(-not $locatorProcess){throw 'Secure session host process from the protected locator is missing.'}
    if(-not $locatorProcess.PSObject.Properties['CommandLine'] -or [string]::IsNullOrWhiteSpace([string]$locatorProcess.CommandLine)){throw 'Secure session host command line is unavailable.'}
    $locatorCommand=[string]$locatorProcess.CommandLine
    if(-not (Test-CcSecureHostCommandLine -CommandLine $locatorCommand -Root $Root)){throw 'Secure session host process does not match the protected locator (approved entry point or root mismatch).'}
    $processObject=Get-Process -Id ([int]$locator.ProcessId) -ErrorAction Stop
    if([long]$processObject.StartTime.ToUniversalTime().Ticks -ne [long]$locator.StartTimeUtcTicks){throw 'Secure session host process has changed since locator creation.'}
    $pipe=New-Object IO.Pipes.NamedPipeClientStream('.', $pipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::None)
    try {
        $pipe.Connect(1500)
        [uint32]$connectedPid=0
        if(-not [CcSecurePipeNative]::GetNamedPipeServerProcessId($pipe.SafePipeHandle.DangerousGetHandle(),[ref]$connectedPid) -or $connectedPid -ne [uint32]$locator.ProcessId){throw 'Connected named pipe server PID does not match its protected locator.'}
        Write-CcSecurePipeLine -Stream $pipe -Text (ConvertTo-Json -Compress -InputObject ([ordered]@{Version=1;Action=$Action}))
        $responseTimeout=if($Action -eq 'Lock'){60000}elseif($Action -eq 'GetClaudeLaunchFiles'){30000}else{5000}
        $responseLimit=if($Action -eq 'GetClaudeLaunchFiles'){12MB}else{65536}
        $line=Read-CcSecurePipeLine -Stream $pipe -TimeoutMilliseconds $responseTimeout -MaxBytes $responseLimit; if (-not $line) { throw 'Invalid secure session response.' }
        $reply=$line | ConvertFrom-Json -ErrorAction Stop
        if (-not $reply.Ok) { throw 'Secure session request failed.' }
        # This connected pipe instance was authenticated before the request. A
        # successful Lock reply may be followed immediately by process exit.
        if ([uint32]$reply.HostPid -ne [uint32]$locator.ProcessId) { throw 'Named pipe server PID did not match its protected locator.' }
        if ($Action -eq 'GetClaudeProvider' -and $reply.Provider) {
            $secret=[string]$reply.Provider.Secret
            $models=ConvertTo-CcSecureHashtable $reply.Provider.Models
            $secure=ConvertTo-SecureString -String $secret -AsPlainText -Force
            $reply.Provider.PSObject.Properties.Remove('Secret')
            $reply.Provider.Models=$models
            $reply.Provider | Add-Member -NotePropertyName Secret -NotePropertyValue $secure
        }
        if ($Action -eq 'GetClaudeLaunchFiles' -and $reply.LaunchBundle -and $reply.LaunchBundle.Provider) {
            $secret=[string]$reply.LaunchBundle.Provider.Secret
            $models=ConvertTo-CcSecureHashtable $reply.LaunchBundle.Provider.Models
            $secure=ConvertTo-SecureString -String $secret -AsPlainText -Force
            $secret=$null
            $reply.LaunchBundle.Provider.PSObject.Properties.Remove('Secret')
            $reply.LaunchBundle.Provider.Models=$models
            $reply.LaunchBundle.Provider | Add-Member -NotePropertyName Secret -NotePropertyValue $secure
        }
        return $reply
    } finally { $pipe.Dispose() }
}

function Get-CcSecureSessionStatus([string]$StickRoot) { Send-CcSecureSessionRequest $StickRoot 'Status' }
function Get-CcSecureSessionClaudeProvider([string]$StickRoot) { (Send-CcSecureSessionRequest $StickRoot 'GetClaudeProvider').Provider }
function Get-CcSecureSessionClaudeLaunchBundle([string]$StickRoot) {
    $reply = Send-CcSecureSessionRequest $StickRoot 'GetClaudeLaunchFiles'
    if (-not $reply.LaunchBundle -or -not $reply.LaunchBundle.Provider -or -not ($reply.LaunchBundle.Provider.Secret -is [Security.SecureString])) {
        throw 'Secure session returned an incomplete Claude launch bundle.'
    }
    return $reply.LaunchBundle
}
function Get-CcSecureSessionClaudeLaunchFiles([string]$StickRoot) {
    $bundle = Get-CcSecureSessionClaudeLaunchBundle -StickRoot $StickRoot
    try { return $bundle.LaunchFiles }
    finally { if ($bundle.Provider.Secret) { $bundle.Provider.Secret.Dispose() } }
}
function Request-CcSecureSessionGui([string]$StickRoot) { Send-CcSecureSessionRequest $StickRoot 'LaunchGui' }
function Test-CcSecureSessionPipeAvailable([string]$StickRoot,[string]$PipeName) {
    if(-not $PipeName){$PipeName=Get-CcSecurePipeName $StickRoot}
    # Test-Path probes the named-pipe namespace without occupying its single
    # server instance or injecting an empty request into the broker loop.
    return [bool](Test-Path -LiteralPath ('\\.\pipe\'+$PipeName) -ErrorAction Stop)
}
function Get-CcSecureManagerSessionDisposition([bool]$PipeAvailable,[bool]$LocatorAvailable) {
    if($PipeAvailable -and $LocatorAvailable){return 'Reuse'}
    if($PipeAvailable){return 'FailClosed'}
    return 'Start'
}
function Test-CcSecureSessionNoSessionResult($Result) {
    if($null -eq $Result){return $false}
    $property=$Result.PSObject.Properties['NoSession']
    return ($null -ne $property -and [bool]$property.Value)
}
function Assert-CcSecureSessionStaleLocator([string]$StickRoot,[string]$PipeName,[string]$LocatorPath) {
    foreach($candidate in @($env:LOCALAPPDATA,(Join-Path $env:LOCALAPPDATA 'AiStick'),(Split-Path -Parent $LocatorPath),$LocatorPath)) {
        if(-not $candidate -or -not (Test-Path -LiteralPath $candidate)){throw 'Secure session locator path is missing.'}
        if((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Secure session locator path contains a reparse point.'}
    }
    $item=Get-Item -LiteralPath $LocatorPath -Force
    if($item.Length -gt 4096){throw 'Secure session locator exceeds the fixed size limit.'}
    $acl=[IO.File]::GetAccessControl($LocatorPath)
    if(-not $acl.AreAccessRulesProtected){throw 'Secure session locator ACL is inheritable.'}
    $allowed=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')
    foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed){throw 'Secure session locator ACL grants access to an unexpected identity.'}
    }
    $record=[IO.File]::ReadAllText($LocatorPath,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop
    $rootFull=[IO.Path]::GetFullPath($StickRoot).TrimEnd('\')
    if([int]$record.Version -ne 1 -or [string]$record.Root -cne $rootFull -or [string]$record.PipeName -cne $PipeName -or [int]$record.ProcessId -le 0 -or [long]$record.StartTimeUtcTicks -le 0){throw 'Secure session locator does not match this volume root.'}
    $process=Get-Process -Id ([int]$record.ProcessId) -ErrorAction SilentlyContinue
    if($process -and [long]$process.StartTime.ToUniversalTime().Ticks -eq [long]$record.StartTimeUtcTicks){throw 'Secure session host is still running but its pipe is unavailable; refusing a duplicate host.'}
    return $true
}
function Lock-CcSecureSession([string]$StickRoot) {
    $pipeName=Get-CcSecurePipeName $StickRoot
    $locatorPath=Get-CcSecureLocatorPath $pipeName
    $hasLocator=[IO.File]::Exists($locatorPath)
    $hasPipe=Test-CcSecureSessionPipeAvailable -StickRoot $StickRoot -PipeName $pipeName
    if(-not $hasPipe) {
        # A stale locator is intentionally left for the next host to validate and
        # remove only after it owns the first pipe instance.
        if($hasLocator){Assert-CcSecureSessionStaleLocator -StickRoot $StickRoot -PipeName $pipeName -LocatorPath $locatorPath|Out-Null}
        return [pscustomobject]@{Locked=$false;NoSession=$true;StaleLocator=$hasLocator}
    }
    if(-not $hasLocator) { throw '加密会话管道仍在运行，但安全定位文件缺失；为避免连接到未经验证的会话，请关闭该会话窗口后重试。' }
    return Send-CcSecureSessionRequest $StickRoot 'Lock'
}
function Assert-CcSecureSessionActionAllowed([string]$Action) {
    if($Action -in @('LaunchGui','Lock') -and $script:lastSaveStatus -eq 'SaveFailed') {
        $detail=[string]$script:lastFailure
        if(-not $detail){$detail='The failed local workspace or encrypted recovery package has not been resolved.'}
        throw ('Cannot '+$Action+': the previous GUI session ended with SaveFailed. The session remains unlocked and retained recovery data must be handled before launching again or locking. '+$detail)
    }
}
function Assert-CcSecureSessionCleanupConfirmed($Control) {
    if(-not $Control -or -not $Control.CleanupComplete) {
        throw 'GUI worker did not confirm cleanup of its isolated plaintext workspace and checkpoint tree.'
    }
}
function Invoke-CcSecureConsoleLock {
    try {
        $null=Invoke-CcSecureSessionAction -Action 'Lock'
        return $true
    } catch {
        Write-Warning ('会话保持解锁，锁定未完成：'+$_.Exception.Message)
        return $false
    }
}

function Read-CcEncryptedStoreUnlockedSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StickRoot,
        [switch]$Create
    )
    $authFailureMessage = '主密码错误，或保险箱认证失败；原文件未修改。'
    $maximumAttempts = 3
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        $password = $null
        $confirm = $null
        try {
            $prompt = if ($Create) { '首次设置 U 盘主密码' } else { '输入 U 盘配置主密码（解锁失败不会启动）' }
            $password = Read-Host $prompt -AsSecureString
            if ($null -eq $password -or $password.Length -eq 0) {
                $remaining = $maximumAttempts - $attempt
                if ($remaining -gt 0) { Write-Host ("主密码不能为空（空输入也计入次数）；还可尝试 {0} 次。" -f $remaining) -ForegroundColor Yellow; continue }
                if ($Create) { throw '三次输入机会已用尽，未创建加密配置。' }
                throw '三次输入机会已用尽，未能解锁加密配置。'
            }

            if ($Create) {
                $confirm = Read-Host '再次输入主密码确认' -AsSecureString
                $matches = $false
                if ($null -ne $confirm -and $password.Length -eq $confirm.Length) {
                    $firstPtr = [IntPtr]::Zero
                    $confirmPtr = [IntPtr]::Zero
                    try {
                        $firstPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
                        $confirmPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirm)
                        $matches = [string]::Equals(
                            [Runtime.InteropServices.Marshal]::PtrToStringBSTR($firstPtr),
                            [Runtime.InteropServices.Marshal]::PtrToStringBSTR($confirmPtr),
                            [StringComparison]::Ordinal
                        )
                    } finally {
                        if ($firstPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstPtr) }
                        if ($confirmPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($confirmPtr) }
                    }
                }
                if (-not $matches) {
                    $remaining = $maximumAttempts - $attempt
                    if ($remaining -gt 0) { Write-Host ("两次主密码不一致；还可重新输入 {0} 次。" -f $remaining) -ForegroundColor Yellow; continue }
                    throw '三次确认机会已用尽，未创建加密配置。'
                }
            }

            try {
                return Open-CcEncryptedStoreSession -StickRoot $StickRoot -Password $password -Create:$Create
            } catch {
                if ($Create -or $_.Exception.Message -cne $authFailureMessage) { throw }
                $remaining = $maximumAttempts - $attempt
                if ($remaining -gt 0) {
                    Write-Host ("主密码验证失败；还可尝试 {0} 次。" -f $remaining) -ForegroundColor Yellow
                    continue
                }
                throw '三次主密码机会已用尽，未能解锁加密配置。'
            }
        } finally {
            if ($null -ne $confirm) { $confirm.Dispose() }
            if ($null -ne $password) { $password.Dispose() }
        }
    }
    throw '三次输入机会已用尽，未能解锁加密配置。'
}

if ($Client) { Send-CcSecureSessionRequest -Root $StickRoot -Action $Request; return }
if ($MyInvocation.InvocationName -eq '.') { return }

$storeModule=Join-Path $scriptDir 'cc-switch-encrypted-store.ps1'
if (-not (Test-Path -LiteralPath $storeModule -PathType Leaf)) { throw 'Encrypted store module is missing.' }
. $storeModule
$session=$null
$locked=$false
$script:runspacePool=$null
$script:scriptDir=$scriptDir
$script:StickRoot=$StickRoot
$script:NetworkMode=$NetworkMode
$script:session=$null
$script:locked=$false
$script:guiProcess=$null
$script:guiPipeline=$null
$script:guiControl=$null
$script:lastSaveStatus='NotSaved'
$script:lastRevision=$null
$script:lastFailure=$null
$pipeName=Get-CcSecurePipeName $StickRoot
$script:pipeName=$pipeName
$firstPipe=$true
$volume=Get-VolumeIdentity -StickRoot $StickRoot
$pipeSecurity=New-Object IO.Pipes.PipeSecurity
$currentSid=[Security.Principal.WindowsIdentity]::GetCurrent().User
$rule=New-Object IO.Pipes.PipeAccessRule($currentSid,[IO.Pipes.PipeAccessRights]::ReadWrite,[Security.AccessControl.AccessControlType]::Allow)
$pipeSecurity.AddAccessRule($rule)
$pipeSecurity.SetAccessRuleProtection($true,$false)
$locatorDir=Join-Path $env:LOCALAPPDATA 'AiStick\SecureSessions'
Assert-ToolboxPlainPath -Path $locatorDir
foreach($pathPart in @($env:LOCALAPPDATA,(Join-Path $env:LOCALAPPDATA 'AiStick'),$locatorDir)){
    if(Test-Path -LiteralPath $pathPart){if((Get-Item -LiteralPath $pathPart -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Secure locator directory path contains a reparse point.'}}
}
[IO.Directory]::CreateDirectory($locatorDir) | Out-Null
foreach($pathPart in @($env:LOCALAPPDATA,(Join-Path $env:LOCALAPPDATA 'AiStick'),$locatorDir)){
    if(-not (Test-Path -LiteralPath $pathPart) -or -not (Get-Item -LiteralPath $pathPart -Force).PSIsContainer -or ((Get-Item -LiteralPath $pathPart -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Secure locator directory failed post-creation verification.'}
}
$locatorAcl=New-Object System.Security.AccessControl.DirectorySecurity
$locatorAcl.SetAccessRuleProtection($true,$false)
foreach($sid in @($currentSid,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),(New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))) { [void]$locatorAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))) }
[IO.Directory]::SetAccessControl($locatorDir,$locatorAcl)
$locatorPath=Get-CcSecureLocatorPath $pipeName
Assert-ToolboxPlainPath -Path $locatorPath
$server=New-CcSecureServerPipe -Name $pipeName -Security $pipeSecurity -First $true
$firstPipe=$false
if([IO.File]::Exists($locatorPath)){
    if ((Get-Item -LiteralPath $locatorPath -Force).Length -gt 4096) { $server.Dispose();throw 'Stale locator exceeds its size limit; inspect it before restarting.' }
    $oldLocator=$null;try{$oldLocator=[IO.File]::ReadAllText($locatorPath,[Text.Encoding]::UTF8)|ConvertFrom-Json}catch{}
    if($oldLocator){$oldProcess=Get-Process -Id ([int]$oldLocator.ProcessId) -ErrorAction SilentlyContinue;if($oldProcess -and [long]$oldProcess.StartTime.ToUniversalTime().Ticks -eq [long]$oldLocator.StartTimeUtcTicks){$server.Dispose();throw 'A secure session host for this root is still running.'}}
    [IO.File]::Delete($locatorPath)
}
$processStart=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
$locatorRecord=[ordered]@{Version=1;Root=[IO.Path]::GetFullPath($StickRoot).TrimEnd('\');PipeName=$pipeName;ProcessId=$PID;StartTimeUtcTicks=$processStart}
$locatorTemp=$locatorPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
if(Test-Path -LiteralPath $locatorTemp){throw 'Secure locator temporary path already exists.'}
[IO.File]::WriteAllText($locatorTemp,(ConvertTo-Json $locatorRecord -Compress),(New-Object Text.UTF8Encoding($false)))
if((Get-Item -LiteralPath $locatorTemp -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Secure locator temporary file is a reparse point.'}
$locatorFileAcl=New-Object System.Security.AccessControl.FileSecurity
$locatorFileAcl.SetAccessRuleProtection($true,$false)
foreach($sid in @($currentSid,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),(New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))) { [void]$locatorFileAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid,'FullControl','None','None','Allow'))) }
[IO.File]::SetAccessControl($locatorTemp,$locatorFileAcl)
[IO.File]::Move($locatorTemp,$locatorPath)

function Invoke-CcSecureSessionAction([string]$Action) {
    switch ($Action) {
        'Status' {
            $provider=$null
            if ($script:session -and -not $script:locked -and $script:session.Revision) { $provider=Get-CcEncryptedClaudeProvider -Session $script:session }
            if ($provider) { $provider.Secret.Dispose(); $name=[string]$provider.Name } else { $name=$null }
            $running=Update-CcSecureGuiState
            if($script:session -and $script:session.Revision -and $script:session.Revision -cne $script:lastRevision){$script:lastRevision=$script:session.Revision;if($script:lastSaveStatus -ne 'SaveFailed'){$script:lastSaveStatus='Saved'}}
            return [ordered]@{Unlocked=[bool]($script:session -and -not $script:locked); ProviderName=$name; PipeName=$script:pipeName; HostPid=$PID;GuiRunning=$running;LastSaveStatus=$script:lastSaveStatus;NetworkMode=$script:NetworkMode}
        }
        'GetClaudeProvider' {
            if (-not $script:session -or $script:locked) { throw 'Session is locked.' }
            if (-not $script:session.Revision) { throw 'No encrypted Claude provider snapshot exists yet.' }
            $p=Get-CcEncryptedClaudeProvider -Session $script:session
            $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($p.Secret)
            try { $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr); $p.Secret.Dispose() }
            return [ordered]@{Provider=[ordered]@{Name=$p.Name;BaseUrl=$p.BaseUrl;Models=$p.Models;AuthEnvironmentName=$p.AuthEnvironmentName;Secret=$plain}}
        }
        'GetClaudeLaunchFiles' {
            if (-not $script:session -or $script:locked) { throw 'Session is locked.' }
            if (-not $script:session.Revision) { throw 'No encrypted configuration snapshot exists yet.' }
            . (Join-Path $script:scriptDir 'cc-switch-claude-launch-files.ps1')
            $bundle=Get-CcEncryptedClaudeLaunchBundle -Session $script:session
            $secretPointer=[IntPtr]::Zero
            try {
                $secretPointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($bundle.Provider.Secret)
                $plainSecret=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer)
                return [ordered]@{LaunchBundle=[ordered]@{Revision=$bundle.Revision;Provider=[ordered]@{Name=$bundle.Provider.Name;BaseUrl=$bundle.Provider.BaseUrl;Models=$bundle.Provider.Models;AuthEnvironmentName=$bundle.Provider.AuthEnvironmentName;Secret=$plainSecret};LaunchFiles=@($bundle.LaunchFiles)}}
            } finally {
                if($secretPointer -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer)}
                $plainSecret=$null
                if($bundle.Provider.Secret){$bundle.Provider.Secret.Dispose()}
            }
        }
        'LaunchGui' {
            if (-not $script:session -or $script:locked) { throw 'Session is locked.' }
            $alreadyRunning=Update-CcSecureGuiState
            Assert-CcSecureSessionActionAllowed -Action 'LaunchGui'
            if($alreadyRunning){return [ordered]@{Started=$false;ProcessId=$PID;GuiRunning=$true}}
            $launcher=Join-Path $script:scriptDir 'cc-switch-isolated.ps1'
            if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Isolated launcher is missing.' }
            $worker=[powershell]::Create()
            $worker.RunspacePool=$script:runspacePool
            $script:guiControl=[hashtable]::Synchronized(@{StopRequested=$false;Saved=$false;CleanupComplete=$false;LastSaveUtc=$null})
            $null=$worker.AddScript('param($path,$stick,$session,$control,$network) & $path -Action Launch -StickRoot $stick -EncryptedSession $session -SessionControl $control -NetworkMode $network').AddArgument($launcher).AddArgument($script:StickRoot).AddArgument($script:session).AddArgument($script:guiControl).AddArgument($script:NetworkMode)
            $handle=$worker.BeginInvoke()
            $script:guiPipeline=[pscustomobject]@{PowerShell=$worker;Handle=$handle}
            return [ordered]@{Started=$true;ProcessId=$PID;GuiRunning=$true}
        }
        'Lock' { Assert-CcSecureSessionActionAllowed -Action 'Lock'; Stop-CcSecureGuiWorker; $script:locked=$true; if ($script:session) { Close-CcEncryptedStoreSession -Session $script:session; $script:session=$null }; return [ordered]@{Locked=$true} }
    }
}

function Update-CcSecureGuiState {
    if(-not $script:guiPipeline){return $false}
    if(-not $script:guiPipeline.Handle.IsCompleted){return $true}
    try {
        $result=@($script:guiPipeline.PowerShell.EndInvoke($script:guiPipeline.Handle))
        if($script:guiPipeline.PowerShell.Streams.Error.Count){throw $script:guiPipeline.PowerShell.Streams.Error[0]}
        Assert-CcSecureSessionCleanupConfirmed -Control $script:guiControl
        if($result.Count){$script:lastSaveStatus=[string]$result[-1].Status}else{$script:lastSaveStatus='GuiExited'}
    } catch {
        $script:lastSaveStatus='SaveFailed'
        $script:lastFailure=$_.Exception.Message
        Write-Warning ('CC Switch 窗口未正常完成：'+$script:lastFailure)
    } finally {$script:guiPipeline.PowerShell.Dispose();$script:guiPipeline=$null}
    return $false
}
function Stop-CcSecureGuiWorker {
    if(-not $script:guiPipeline){return}
    if($script:guiControl){$script:guiControl.StopRequested=$true}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not $script:guiPipeline.Handle.IsCompleted -and $watch.Elapsed.TotalSeconds -lt 30){Start-Sleep -Milliseconds 100}
    if(-not $script:guiPipeline.Handle.IsCompleted){throw 'GUI worker did not finish its stopped encrypted save; secure session remains unlocked.'}
    try{
        $result=@($script:guiPipeline.PowerShell.EndInvoke($script:guiPipeline.Handle))
        if($script:guiPipeline.PowerShell.Streams.Error.Count){throw ([string]$script:guiPipeline.PowerShell.Streams.Error[0])}
        Assert-CcSecureSessionCleanupConfirmed -Control $script:guiControl
        if($script:guiControl -and $script:guiControl.Saved){$script:lastSaveStatus='Saved';$script:lastFailure=$null}
        elseif($script:session -and -not $script:session.Revision){$script:lastSaveStatus='NoSnapshot';$script:lastFailure=$null}
        else{throw 'GUI worker did not confirm a final encrypted snapshot.'}
    }catch{
        $script:lastSaveStatus='SaveFailed'
        $script:lastFailure=$_.Exception.Message
        throw
    }finally{$script:guiPipeline.PowerShell.Dispose();$script:guiPipeline=$null;$script:guiControl=$null}
}

try {
    $storeState=Get-CcEncryptedStoreStatus -StickRoot $StickRoot
    if($storeState.State -eq 'Corrupt'){throw '加密配置结构校验失败，已停止解锁；请保留盘内文件以便恢复。'}
    if($storeState.State -eq 'RecoveryRequired') {
        Write-Host '检测到上次配置保存未完成。解锁后将校验最近已提交的配置，并先保留完整加密备份，再尝试恢复。' -ForegroundColor Yellow
    }
    $createStore=($storeState.State -eq 'Absent')
    $session=Read-CcEncryptedStoreUnlockedSession -StickRoot $StickRoot -Create:$createStore
    if($storeState.State -eq 'RecoveryRequired') {
        . (Join-Path $scriptDir 'cc-switch-store-recovery.ps1')
        $recovered = Repair-CcEncryptedStore -Session $session
        Write-Host ('已恢复最近已提交的加密配置；原始加密备份：' + $recovered.ArchivePath) -ForegroundColor Green
    }
    $migration=Join-Path $scriptDir 'cc-switch-migration.ps1'
    if(Test-Path -LiteralPath $migration -PathType Leaf){. $migration;$null=Initialize-CcEncryptedStoreFromLegacy -StickRoot $StickRoot -Session $session}
    if($ImportToolboxBeforeLaunch){
        . (Join-Path $scriptDir 'cc-switch-toolbox-migration.ps1')
        $oldVaultPassword=$null
        try {
            if(Test-ProviderVaultPresent -KeysFile (Join-Path $StickRoot 'config\keys.env')) { $oldVaultPassword=Read-Host '输入原工具箱凭据保险箱密码（用于一次性迁移）' -AsSecureString }
            $null=Import-CcToolboxProviders -StickRoot $StickRoot -Session $session -VaultPassword $oldVaultPassword
            Write-Host '原工具箱配置已导入 CC Switch 加密快照，旧数据保留。请在窗口中核对后启用唯一入口。' -ForegroundColor Green
        } finally { if($oldVaultPassword){$oldVaultPassword.Dispose()} }
    }
    $script:runspacePool=[RunspaceFactory]::CreateRunspacePool(1,2)
    $script:runspacePool.Open()
    Write-Host '会话已解锁。此窗口可以最小化；关闭此窗口会锁定并关闭 U 盘 CC Switch。新 Claude 窗口可读取当前供应商；输入 L 锁定退出。' -ForegroundColor Green
    Write-Host ('本地 broker：\\.\pipe\'+$pipeName)
    $null=Invoke-CcSecureSessionAction -Action 'LaunchGui'
    while (-not $locked) {
        $lockKey=$false
        if (-not [Console]::IsInputRedirected) { try { if ([Console]::KeyAvailable) { $lockKey=([Console]::ReadKey($true).Key -eq [ConsoleKey]::L) } } catch { } }
        if($lockKey){$locked=Invoke-CcSecureConsoleLock;if($locked){break}}
        if (-not (Test-StickPresent -Expected $volume)) { $locked=$true; break }
        $null=Update-CcSecureGuiState
        if(-not $server){$server=New-CcSecureServerPipe -Name $pipeName -Security $pipeSecurity -First $false}
        try {
            $wait=$server.BeginWaitForConnection($null,$null)
            while (-not $wait.AsyncWaitHandle.WaitOne(250)) {
                $lockKey=$false
                if (-not [Console]::IsInputRedirected) { try { if ([Console]::KeyAvailable) { $lockKey=([Console]::ReadKey($true).Key -eq [ConsoleKey]::L) } } catch { } }
                if($lockKey){$locked=Invoke-CcSecureConsoleLock;if($locked){break}}
                if (-not (Test-StickPresent -Expected $volume)) { $locked=$true; break }
                $null=Update-CcSecureGuiState
            }
            if ($locked) { break }
            $server.EndWaitForConnection($wait)
            $line=Read-CcSecurePipeLine -Stream $server -TimeoutMilliseconds 5000 -MaxBytes 4096; if (-not $line) { throw 'Invalid request size.' }
            $req=$line | ConvertFrom-Json -ErrorAction Stop
            if ([int]$req.Version -ne 1 -or [string]$req.Action -notin @('Status','GetClaudeProvider','GetClaudeLaunchFiles','LaunchGui','Lock')) { throw 'Unsupported broker operation.' }
            $data=[ordered]@{Provider=$null;LaunchFiles=$null;LaunchBundle=$null;Unlocked=$null;ProviderName=$null;Started=$null;ProcessId=$null;Locked=$null;GuiRunning=$null;LastSaveStatus=$null}
            $actionData=Invoke-CcSecureSessionAction -Action ([string]$req.Action)
            foreach($key in $actionData.Keys){$data[$key]=$actionData[$key]}
            $responseText=ConvertTo-Json -Compress -Depth 12 -InputObject ([ordered]@{Ok=$true;Provider=$data['Provider'];LaunchFiles=$data['LaunchFiles'];LaunchBundle=$data['LaunchBundle'];Unlocked=$data['Unlocked'];ProviderName=$data['ProviderName'];Started=$data['Started'];ProcessId=$data['ProcessId'];Locked=$data['Locked'];HostPid=$PID;GuiRunning=$data['GuiRunning'];LastSaveStatus=$data['LastSaveStatus'];NetworkMode=$script:NetworkMode})
            $responseLimit=if($req.Action -eq 'GetClaudeLaunchFiles'){12MB}else{65536}
            if([Text.Encoding]::UTF8.GetByteCount($responseText)+1 -gt $responseLimit){throw 'Secure response exceeds the fixed limit.'}
            Write-CcSecurePipeLine -Stream $server -Text $responseText -TimeoutMilliseconds 30000
            if ($req.Action -eq 'Lock') { $locked=$true }
        } catch {
            try { if ($server.IsConnected) { Write-CcSecurePipeLine -Stream $server -Text '{"Ok":false}' } } catch { }
        } finally { $responseText=$null;$data=$null;$actionData=$null;$plainSecret=$null;try{$server.Dispose()}catch{};$server=$null;try{$wait.AsyncWaitHandle.Dispose()}catch{} }
    }
} finally {
    if ($server) { try { $server.Dispose() } catch { } }
    if ($script:guiPipeline) { try { Stop-CcSecureGuiWorker } catch { } }
    if ($script:runspacePool) { try { $script:runspacePool.Close();$script:runspacePool.Dispose() } catch { } }
    if ($session) { try { Close-CcEncryptedStoreSession -Session $session } catch { } }
    if($locatorPath -and [IO.File]::Exists($locatorPath)){try{$r=[IO.File]::ReadAllText($locatorPath,[Text.Encoding]::UTF8)|ConvertFrom-Json;if([int]$r.ProcessId -eq $PID){[IO.File]::Delete($locatorPath)}}catch{}}
    Write-Host '解锁会话已关闭。'
}
