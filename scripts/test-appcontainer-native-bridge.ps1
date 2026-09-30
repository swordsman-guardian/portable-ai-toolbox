 [CmdletBinding()]
param([ValidateRange(5,120)][int]$TimeoutSeconds = 30)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$bridgeProbeTimeout = $TimeoutSeconds
. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')
$TimeoutSeconds = $bridgeProbeTimeout

$fixtureRoot = $null
$state = $null
$pipeHost = $null
$hostPipeServer = $null
$hostRoot = $null
$passed = 0
$failed = 0
$blocked = 0
$checks = New-Object 'System.Collections.Generic.List[object]'
$cleanupSafe = $true
$launchBlocked = $false
$workerDiagnostic = $null
$workerSource = @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Net.Sockets;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.ComponentModel;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;

public static class AppContainerNativeBridgeProbe {
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle; }
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl,uint revision,out IntPtr descriptor,out uint size);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateNamedPipeW(string name,uint openMode,uint pipeMode,uint maxInstances,uint outBuffer,uint inBuffer,uint timeout,ref SecurityAttributes security);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool ConnectNamedPipe(IntPtr pipe,IntPtr overlapped);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr LocalFree(IntPtr memory);
    static string Error(Exception e) {
        var sx=e as SocketException;
        var wx=e as Win32Exception;
        return e.GetType().Name+" HResult=0x"+e.HResult.ToString("X8")+(sx==null?"":" NativeErrorCode="+sx.NativeErrorCode+" SocketError="+sx.SocketErrorCode)+(wx==null?"":" NativeErrorCode="+wx.NativeErrorCode)+": "+e.Message;
    }
    static string Escape(string s) { return (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", " ").Replace("\n", " "); }
    static void ReadExactly(Stream stream, byte[] data) {
        int offset = 0;
        while (offset < data.Length) { var read=stream.BeginRead(data,offset,data.Length-offset,null,null); if(!read.AsyncWaitHandle.WaitOne(5000)) throw new TimeoutException("Synthetic pipe read exceeded five seconds."); int n=stream.EndRead(read); if (n <= 0) throw new EndOfStreamException(); offset += n; }
    }
    public static int Main(string[] args) {
        if (args.Length != 7) return 10;
        string pipeName=args[0], hostPipeName=args[1], sidPath=args[2], readyPath=args[3], resultPath=args[4], sentinelPath=args[5], hostReadyPath=args[6];
        bool token=false, pipeConnected=false, pipeRoundTrip=false, hostPipeConnected=false, hostPipeRoundTrip=false, loopbackBound=false, loopbackRoundTrip=false, sentinelDenied=false;
        string pipeError="", pipeSddl="", hostPipeError="", loopbackError="", sentinelError="";
        int localPort=0;
        string containerSid="";
        try {
            var sw=System.Diagnostics.Stopwatch.StartNew();
            while(!File.Exists(sidPath) && sw.ElapsedMilliseconds<10000) Thread.Sleep(50);
            if(!File.Exists(sidPath)) throw new TimeoutException("Host did not provide the launcher-verified AppContainer SID.");
            containerSid=File.ReadAllText(sidPath).Trim(); token=containerSid.StartsWith("S-1-15-2-",StringComparison.Ordinal);
            if(!token) throw new InvalidDataException("Host-provided SID is not an AppContainer package SID.");
        } catch(Exception e) { pipeError="launcher SID handoff: "+Error(e); }
        try {
            pipeSddl="D:P(A;;GA;;;"+WindowsIdentity.GetCurrent().User.Value+")(A;;GA;;;"+containerSid+")S:(ML;;NW;;;LW)";
            IntPtr descriptor=IntPtr.Zero, handle=IntPtr.Zero;
            try {
                uint descriptorSize;
                if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(pipeSddl,1,out descriptor,out descriptorSize)) throw new Win32Exception(Marshal.GetLastWin32Error());
                var security=new SecurityAttributes(); security.Length=Marshal.SizeOf(typeof(SecurityAttributes)); security.Descriptor=descriptor; security.InheritHandle=false;
                handle=CreateNamedPipeW("\\\\.\\pipe\\LOCAL\\"+pipeName,0x00000003|0x00080000|0x40000000,0,1,4096,4096,0,ref security);
                if(handle==IntPtr.Zero || handle==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
                using(var pipe=new NamedPipeServerStream(PipeDirection.InOut,true,false,new SafePipeHandle(handle,true))) {
                    handle=IntPtr.Zero;
                    var accept=pipe.BeginWaitForConnection(null,null);
                    File.WriteAllText(readyPath,"ready",new UTF8Encoding(false));
                    if(!accept.AsyncWaitHandle.WaitOne(10000)) throw new TimeoutException("Synthetic AC pipe accept exceeded ten seconds.");
                    pipe.EndWaitForConnection(accept); pipeConnected=true;
                    byte[] input=new byte[16]; ReadExactly(pipe,input);
                    byte[] answer=new byte[input.Length]; for(int i=0;i<input.Length;i++) answer[i]=(byte)(input[i]^0x5a);
                    pipe.Write(answer,0,answer.Length); pipe.Flush(); pipeRoundTrip=true;
                }
            } finally { if(handle!=IntPtr.Zero && handle!=new IntPtr(-1)) CloseHandle(handle); if(descriptor!=IntPtr.Zero) LocalFree(descriptor); }
        } catch(Exception e) { pipeError=Error(e); }
        try {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start(); loopbackBound=true; localPort=((IPEndPoint)listener.LocalEndpoint).Port;
            Exception serverError=null;
            var server=ThreadPool.QueueUserWorkItem(_ => { try { using(var accepted=listener.AcceptTcpClient()) using(var s=accepted.GetStream()) { byte[] input=new byte[8]; ReadExactly(s,input); for(int i=0;i<input.Length;i++) input[i]^=0x33; s.Write(input,0,input.Length); s.Flush(); } } catch(Exception e) { serverError=e; } });
            try {
                using(var client=new TcpClient(AddressFamily.InterNetwork)) {
                    var ar=client.BeginConnect(IPAddress.Loopback,localPort,null,null);
                    if(!ar.AsyncWaitHandle.WaitOne(5000)) throw new TimeoutException("Connect to same-process loopback listener exceeded 5 seconds.");
                    client.EndConnect(ar); client.ReceiveTimeout=5000; client.SendTimeout=5000;
                    byte[] input=Encoding.ASCII.GetBytes("bridge123"); Array.Resize(ref input,8);
                    using(var s=client.GetStream()) { s.Write(input,0,input.Length); s.Flush(); byte[] output=new byte[8]; ReadExactly(s,output); for(int i=0;i<8;i++) if(output[i]!=(byte)(input[i]^0x33)) throw new InvalidDataException("Loopback echo mismatch."); }
                    loopbackRoundTrip=true;
                }
            } finally { listener.Stop(); }
            if(serverError!=null) throw serverError;
        } catch(Exception e) { loopbackError=Error(e); }
        try {
            var sw=System.Diagnostics.Stopwatch.StartNew();
            while(!File.Exists(hostReadyPath) && sw.ElapsedMilliseconds<15000) Thread.Sleep(50);
            if(!File.Exists(hostReadyPath)) throw new TimeoutException("Host did not create the restricted local pipe.");
            using(var client=new NamedPipeClientStream(".","LOCAL\\"+hostPipeName,PipeDirection.InOut,PipeOptions.Asynchronous)) {
                client.Connect(10000); hostPipeConnected=true;
                byte[] input=new byte[16]; ReadExactly(client,input);
                for(int i=0;i<input.Length;i++) input[i]^=0x6d;
                client.Write(input,0,input.Length); client.Flush(); hostPipeRoundTrip=true;
            }
        } catch(Exception e) { hostPipeError=Error(e); }
        try { File.AppendAllText(sentinelPath,"synthetic-attempt",new UTF8Encoding(false)); }
        catch(UnauthorizedAccessException e) { sentinelDenied=true; sentinelError=Error(e); }
        catch(System.Security.SecurityException e) { sentinelDenied=true; sentinelError=Error(e); }
        catch(Exception e) { sentinelError=Error(e); }
        string json="{\"tokenIsAppContainer\":"+token.ToString().ToLowerInvariant()+
            ",\"pipeConnected\":"+pipeConnected.ToString().ToLowerInvariant()+
            ",\"pipeRoundTrip\":"+pipeRoundTrip.ToString().ToLowerInvariant()+
            ",\"appContainerSid\":\""+Escape(containerSid)+"\",\"pipeSddl\":\""+Escape(pipeSddl)+"\",\"pipeError\":\""+Escape(pipeError)+"\""+
            ",\"hostPipeConnected\":"+hostPipeConnected.ToString().ToLowerInvariant()+
            ",\"hostPipeRoundTrip\":"+hostPipeRoundTrip.ToString().ToLowerInvariant()+",\"hostPipeError\":\""+Escape(hostPipeError)+"\""+
            ",\"loopbackBound\":"+loopbackBound.ToString().ToLowerInvariant()+
            ",\"loopbackRoundTrip\":"+loopbackRoundTrip.ToString().ToLowerInvariant()+
            ",\"loopbackPort\":"+localPort+",\"loopbackError\":\""+Escape(loopbackError)+"\""+
            ",\"hostSentinelDenied\":"+sentinelDenied.ToString().ToLowerInvariant()+
            ",\"hostSentinelError\":\""+Escape(sentinelError)+"\"}";
        try { File.WriteAllText(resultPath,json,new UTF8Encoding(false)); } catch { return 12; }
        return token ? 0 : 13;
    }
}
'@

function Get-Hash([string]$Path) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $stream=[IO.File]::OpenRead($Path); try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') } finally { $stream.Dispose() } }
    finally { $sha.Dispose() }
}
function Remove-OwnedProbeTree([string]$Path,[string]$Prefix) {
    if (-not $Path -or -not [IO.Directory]::Exists($Path)) { return }
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    $leaf=Split-Path -Leaf $full; $id=[guid]::Empty
    if (-not $leaf.StartsWith($Prefix,[StringComparison]::Ordinal) -or -not [guid]::TryParseExact($leaf.Substring($Prefix.Length),'N',[ref]$id) -or
        -not [string]::Equals((Split-Path -Parent $full).TrimEnd('\','/'),$temp,[StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup refused a path outside the owned unique temp directory.' }
    $links=@(Get-ChildItem -LiteralPath $full -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($links.Count) { throw 'Cleanup refused a synthetic tree containing reparse points.' }
    Remove-Item -LiteralPath $full -Recurse -Force
}
function Set-HostOnlyAcl([string]$Path) {
    $acl=[IO.Directory]::GetAccessControl($Path); $acl.SetAccessRuleProtection($true,$false)
    foreach($entry in @($acl.Access)) { [void]$acl.RemoveAccessRuleAll($entry) }
    $sids=@([Security.Principal.WindowsIdentity]::GetCurrent().User,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),(New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach($sid in $sids) { $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,[Security.AccessControl.FileSystemRights]::FullControl,([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow); [void]$acl.AddAccessRule($rule) }
    [IO.Directory]::SetAccessControl($Path,$acl)
}
function Write-Result([string]$name,[bool]$ok,[string]$detail,[bool]$wasBlocked=$false) {
    $status=if($ok){'PASS'}elseif($wasBlocked){'BLOCKED'}else{'FAIL'}
    $script:checks.Add([pscustomobject]@{ name=$name; status=$status; detail=$detail })
    if ($ok) { $script:passed++; Write-Host "PASS $name - $detail" }
    elseif ($wasBlocked) { $script:blocked++; Write-Host "BLOCKED $name - $detail" }
    else { $script:failed++; Write-Host "FAIL $name - $detail" }
}

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class AppContainerBridgeHostPipe {
 [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle; }
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl,uint revision,out IntPtr descriptor,out uint size);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateNamedPipeW(string name,uint openMode,uint pipeMode,uint maxInstances,uint outBuffer,uint inBuffer,uint timeout,ref SecurityAttributes security);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr LocalFree(IntPtr memory);
 public static NamedPipeServerStream Create(string name,string sddl) {
  IntPtr descriptor=IntPtr.Zero; uint size;
  if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl,1,out descriptor,out size)) throw new Win32Exception(Marshal.GetLastWin32Error());
  try { var sa=new SecurityAttributes(); sa.Length=Marshal.SizeOf(typeof(SecurityAttributes)); sa.Descriptor=descriptor; sa.InheritHandle=false;
   IntPtr h=CreateNamedPipeW("\\\\.\\pipe\\LOCAL\\"+name,0x00000003|0x00080000|0x40000000,0,1,4096,4096,0,ref sa);
   if(h==IntPtr.Zero || h==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
   return new NamedPipeServerStream(PipeDirection.InOut,true,false,new SafePipeHandle(h,true));
  } finally { LocalFree(descriptor); }
 }
}
'@ -ErrorAction Stop

try {
    $tmp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $volume=Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='"+[IO.Path]::GetPathRoot($tmp).TrimEnd('\')+"'") -ErrorAction Stop | Select-Object -First 1
    if ($volume.FileSystem -ne 'NTFS') { throw 'The synthetic security probe requires an NTFS temp volume.' }
    $fixtureRoot=New-AppContainerProbeFixtureRoot
    $id=(Split-Path -Leaf $fixtureRoot).Substring('aistick-ac-probe-'.Length)
    $appDir=Join-Path $fixtureRoot 'app'; $stick=Join-Path $fixtureRoot 'stick'; $runtime=Join-Path $fixtureRoot 'runtime'
    foreach($dir in @($appDir,$stick,$runtime)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
    $hostRoot=Join-Path $tmp ('aistick-ac-bridge-host-'+[guid]::NewGuid().ToString('N')); [IO.Directory]::CreateDirectory($hostRoot) | Out-Null
    Set-HostOnlyAcl $hostRoot
    $sentinel=Join-Path $hostRoot 'sentinel.txt'; [IO.File]::WriteAllText($sentinel,'host-sentinel-v1',[Text.UTF8Encoding]::new($false)); $sentinelHash=Get-Hash $sentinel
    $exe=Join-Path $appDir 'cc-switch.exe'
    Add-Type -TypeDefinition $workerSource -OutputType ConsoleApplication -OutputAssembly $exe -ErrorAction Stop
    $pipeName='AiStick.NativeBridge.'+[guid]::NewGuid().ToString('N')
    $hostPipeName='AiStick.NativeBridge.Host.'+[guid]::NewGuid().ToString('N')
    $sidPath=Join-Path $stick 'launcher-verified-appcontainer.sid'
    $hostReadyPath=Join-Path $stick 'host-pipe-ready.txt'
    $ready=Join-Path $stick 'worker-ready.txt'; $resultPath=Join-Path $stick 'worker-result.json'
    $fixture=[ordered]@{ Root=$fixtureRoot; Exe=$exe; StickRoot=$stick; RuntimeRoot=$runtime; Environment=[ordered]@{ HOME=$stick; USERPROFILE=$stick; APPDATA=$stick; LOCALAPPDATA=$stick; CC_SWITCH_TEST_HOME=$stick; TEMP=$stick; TMP=$stick }; Arguments=@($pipeName,$hostPipeName,$sidPath,$ready,$resultPath,$sentinel,$hostReadyPath) }
    $fixturePath=Join-Path $fixtureRoot 'fixture.json'
    [IO.File]::WriteAllText($fixturePath,(ConvertTo-Json -InputObject $fixture -Depth 8),[Text.UTF8Encoding]::new($false))
    $loaded=Read-AppContainerFixture -Path $fixturePath
    $state=Start-AppContainerProbeProcess -Fixture $loaded -NetworkMode InternetClient
    $launchedSid=[string]$state.AppContainerSid
    [IO.File]::WriteAllText($sidPath,$launchedSid,[Text.UTF8Encoding]::new($false))
    $hostPipeSddl='D:P(A;;GA;;;'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value+')(A;;GA;;;'+$launchedSid+')S:(ML;;NW;;;LW)'
    $hostPipeObjectCreated=$false; $hostPipeError=''; $hostPipeMatch=$false; $hostPipeAsyncWait=$null
    try {
        $hostPipeServer=[AppContainerBridgeHostPipe]::Create($hostPipeName,$hostPipeSddl)
        $hostPipeObjectCreated=$true
        [IO.File]::WriteAllText($hostReadyPath,'ready',[Text.UTF8Encoding]::new($false))
        $hostPipeAsyncWait=$hostPipeServer.BeginWaitForConnection($null,$null)
    } catch { $hostPipeError=$_.Exception.GetType().Name+': '+$_.Exception.Message }
    $waitUntil=[Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($ready) -and $waitUntil.Elapsed.TotalSeconds -lt $TimeoutSeconds) { Start-Sleep -Milliseconds 50 }
    $readyFound=[IO.File]::Exists($ready)
    if (-not $readyFound) {
        $workerWait=Wait-AppContainerProbeProcess -State $state -TimeoutSeconds 1
        if ($workerWait.Completed -and $workerWait.ExitCode -eq 1260) {
            $checks.Add([pscustomobject]@{name='isolated worker launch';status='BLOCKED';detail='Windows application control policy denied execution (1260).'})
            $blocked++; $launchBlocked=$true; Write-Host 'BLOCKED isolated worker launch - Windows application control policy denied execution (1260).'
        } elseif ($workerWait.Completed -and -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "Isolated worker failed before it wrote diagnostics (exit=$($workerWait.ExitCode))."
        }
    }
    if (-not $launchBlocked) {
    $pipeMatch=$false
    $acPipeError=if($readyFound){''}else{'AppContainer worker did not create the pipe server.'}
    if($readyFound) {
        $pipeHost=New-Object IO.Pipes.NamedPipeClientStream('.', ('LOCAL\'+$pipeName), [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
        try {
            $pipeHost.Connect([Math]::Min(15000,$TimeoutSeconds*1000))
            $challenge=[byte[]](0..15 | ForEach-Object { [byte](($_ * 13 + 7) -band 255) })
            $pipeHost.Write($challenge,0,$challenge.Length); $pipeHost.Flush()
            $answer=New-Object byte[] $challenge.Length; $offset=0
            while($offset -lt $answer.Length) { $read=$pipeHost.BeginRead($answer,$offset,$answer.Length-$offset,$null,$null); if(-not $read.AsyncWaitHandle.WaitOne(5000)){throw "Host pipe read deadline exceeded"}; $n=$pipeHost.EndRead($read); if($n -le 0) { throw 'Named-pipe peer closed before returning bytes.' }; $offset+=$n }
            $expected=[byte[]]($challenge | ForEach-Object { [byte]($_ -bxor 0x5a) })
            $pipeMatch=$true; for($i=0;$i -lt $answer.Length;$i++) { if($answer[$i] -ne $expected[$i]) { $pipeMatch=$false } }
        } catch { $acPipeError=$_.Exception.GetType().Name+': '+$_.Exception.Message
        } finally { $pipeHost.Dispose(); $pipeHost=$null }
    }
    try {
        if(-not $hostPipeObjectCreated) { throw ('Host-created pipe object was not created: '+$hostPipeError) }
        if(-not $hostPipeAsyncWait.AsyncWaitHandle.WaitOne([Math]::Min(15000,$TimeoutSeconds*1000))) { throw 'AppContainer did not connect to host-created pipe within the deadline.' }
        $hostPipeServer.EndWaitForConnection($hostPipeAsyncWait)

        $hostChallenge=[byte[]](0..15 | ForEach-Object { [byte](($_ * 11 + 3) -band 255) })
        $hostPipeServer.Write($hostChallenge,0,$hostChallenge.Length); $hostPipeServer.Flush()
        $hostAnswer=New-Object byte[] $hostChallenge.Length; $hostOffset=0
        while($hostOffset -lt $hostAnswer.Length) { $read=$hostPipeServer.BeginRead($hostAnswer,$hostOffset,$hostAnswer.Length-$hostOffset,$null,$null); if(-not $read.AsyncWaitHandle.WaitOne(5000)){throw "Host server read deadline exceeded"}; $n=$hostPipeServer.EndRead($read); if($n -le 0) { throw 'AppContainer closed host pipe before replying.' }; $hostOffset+=$n }
        $hostExpected=[byte[]]($hostChallenge | ForEach-Object { [byte]($_ -bxor 0x6d) })
        $hostPipeMatch=$true; for($i=0;$i -lt $hostAnswer.Length;$i++) { if($hostAnswer[$i] -ne $hostExpected[$i]) { $hostPipeMatch=$false } }
    } catch { $hostPipeError=$_.Exception.GetType().Name+': '+$_.Exception.Message
    } finally { if($hostPipeServer){$hostPipeServer.Dispose();$hostPipeServer=$null} }
    $workerWait=Wait-AppContainerProbeProcess -State $state -TimeoutSeconds ([Math]::Max($TimeoutSeconds,30))
    if (-not $workerWait.Completed) { throw 'AppContainer feasibility worker timed out.' }
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw "Worker emitted no diagnostic result (exit=$($workerWait.ExitCode))." }
    $result=[IO.File]::ReadAllText($resultPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    $state | Add-Member -MemberType NoteProperty -Name Completed -Value $false -Force
    Complete-AppContainerProbeProcess -State $state; $state=$null
    $hashAfter=Get-Hash $sentinel
    $workerDiagnostic=[ordered]@{ tokenIsAppContainer=[bool]$result.tokenIsAppContainer; appContainerSid=[string]$result.appContainerSid; pipeConnected=[bool]$result.pipeConnected; pipeRoundTrip=[bool]$result.pipeRoundTrip; pipeSddlConstructed=[string]$result.pipeSddl; pipeError=[string]$result.pipeError; hostPipeConnected=[bool]$result.hostPipeConnected; hostPipeRoundTrip=[bool]$result.hostPipeRoundTrip; hostPipeSddl=$hostPipeSddl; hostPipeObjectCreated=$hostPipeObjectCreated; hostPipeError=[string]$result.hostPipeError; hostPipeServerError=$hostPipeError; loopbackBound=[bool]$result.loopbackBound; loopbackRoundTrip=[bool]$result.loopbackRoundTrip; loopbackPort=[int]$result.loopbackPort; loopbackError=[string]$result.loopbackError; hostSentinelDenied=[bool]$result.hostSentinelDenied; hostSentinelError=[string]$result.hostSentinelError; sentinelHashUnchanged=($hashAfter -ceq $sentinelHash) }
    $sidSet=@([string]$result.appContainerSid,[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    $daclText=([string]$result.pipeSddl -split 'S:',2)[0]
    $aceSids=@([regex]::Matches($daclText,';;;([^;)]+)\)') | ForEach-Object { $_.Groups[1].Value })
    $unexpectedAces=@($aceSids | Where-Object { $sidSet -notcontains $_ })
    $sddlSidMatches=(@($aceSids).Count -eq 2 -and @($sidSet).Count -eq 2 -and
        $unexpectedAces.Count -eq 0 -and
        ([string]$result.pipeSddl -match 'S:\(ML;;NW;;;LW\)'))
    Write-Result 'AppContainer token identity verified by launcher and SID handoff' ([bool]$result.tokenIsAppContainer -and [string]$result.appContainerSid -ceq $launchedSid) $result.appContainerSid
    Write-Result 'AC-created pipe SDDL constructed with exact trustees and low IL' $sddlSidMatches ([string]$result.pipeSddl+'; pipeConnected='+[string]$result.pipeConnected)
    $pipeDetail=if([string]$result.pipeError -match 'NativeErrorCode='){[string]$result.pipeError}elseif($acPipeError){$acPipeError}else{[string]$result.pipeError}
    $pipeAclObserved=([string]$result.pipeSddl -match 'S:\(ML;;NW;;;LW\)')
    $pipeBlocked=((-not $result.pipeRoundTrip) -and $pipeAclObserved -and ($pipeDetail -match 'Access.?denied|NativeErrorCode=5|error code 5|0x00000005'))
    Write-Result 'host and AppContainer exchanged synthetic challenge bytes' ([bool]$result.pipeRoundTrip -and $pipeMatch) $pipeDetail $pipeBlocked
    $hostPipeDetail=if($hostPipeError){$hostPipeError}else{[string]$result.hostPipeError}
    $hostPipeBlocked=((-not $result.hostPipeRoundTrip) -and $hostPipeDetail -match 'Access.?denied|NativeErrorCode=5|error code 5|0x00000005')
    Write-Result 'host-created restricted pipe object and AppContainer client exchanged synthetic bytes' ([bool]$result.hostPipeRoundTrip -and $hostPipeMatch) ($hostPipeSddl+'; '+$hostPipeDetail) $hostPipeBlocked
    Write-Result 'AppContainer bound a loopback TCP listener' ([bool]$result.loopbackBound) $result.loopbackError
    Write-Result 'same-AppContainer loopback TCP round trip' ([bool]$result.loopbackRoundTrip) ("NetworkMode=InternetClient; "+$result.loopbackError) ($result.loopbackBound -and -not $result.loopbackRoundTrip -and $result.loopbackError -match 'NativeErrorCode=(10013|10060)')
    Write-Result 'host-only sentinel stayed denied and unchanged' ([bool]$result.hostSentinelDenied -and $hashAfter -ceq $sentinelHash) $result.hostSentinelError
    }
} catch {
    $failed++; Write-Host ("FAIL setup - {0} (at {1})" -f $_.Exception.Message,$_.ScriptStackTrace)
} finally {
    if ($state) { try { Complete-AppContainerProbeProcess -State $state; $state=$null } catch { $cleanupSafe=$false; Write-Host 'CLEANUP FAILED: preserving the owned probe tree.' } }
    if ($pipeHost) { $pipeHost.Dispose() }
    if ($cleanupSafe) {
        try { Remove-OwnedProbeTree $hostRoot 'aistick-ac-bridge-host-' } catch { $cleanupSafe=$false; Write-Host ('CLEANUP FAILED: host tree retained: '+$_.Exception.Message) }
        if ($cleanupSafe) { try { Remove-OwnedProbeTree $fixtureRoot 'aistick-ac-probe-' } catch { $cleanupSafe=$false; Write-Host ('CLEANUP FAILED: fixture retained: '+$_.Exception.Message) } }
    }
}
Write-Host "`nNative bridge feasibility: $passed passed, $blocked blocked, $failed failed."
$exitCode=if($failed -gt 0 -or -not $cleanupSafe){1}elseif($blocked -gt 0){2}else{0}
$summary=[ordered]@{
    schema=1; timestampUtc=[DateTime]::UtcNow.ToString('o'); networkMode='InternetClient';
    checks=@($checks.ToArray()); worker=$workerDiagnostic; passed=$passed; blocked=$blocked; failed=$failed;
    sameIdentityTwoProcessLoopback='NotTested'; nativeGuiProxy='NotTested'; nativeProxyReady=$false; cleanupSafe=$cleanupSafe; exitCode=$exitCode
}
$summaryPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'logs\cc-switch-native-bridge-probe.json'
try { [IO.File]::WriteAllText($summaryPath,(ConvertTo-Json -InputObject $summary -Depth 8),[Text.UTF8Encoding]::new($false)); Write-Host "JSON result: $summaryPath" }
catch { Write-Host ('FAIL could not persist structured result: '+$_.Exception.Message); $exitCode=1 }
exit $exitCode
