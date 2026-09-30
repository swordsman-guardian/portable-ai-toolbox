[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')

$script:root = $null
$script:hostRoot = $null
$script:state = $null
$script:mutex = $null
$script:passed = 0
$script:failed = 0
$script:cleanupSafe = $true
$script:hostToAcSucceeded = $false

function Assert-Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Record-Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host ("FAIL {0} - {1}" -f $Name, $_.Exception.Message) }
}
function Get-Hash([string]$Path) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash([IO.File]::ReadAllBytes($Path))).Replace('-', '')) }
    finally { $algorithm.Dispose() }
}
function Protect-HostDirectory([string]$Path) {
    $acl = [IO.Directory]::GetAccessControl($Path)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleAll($rule) }
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User, (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')), (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, [Security.AccessControl.FileSystemRights]::FullControl,
            ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($rule)
    }
    [IO.Directory]::SetAccessControl($Path, $acl)
}
function Remove-OwnedTree([string]$Path, [string]$Prefix) {
    if (-not $Path -or -not [IO.Directory]::Exists($Path)) { return }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    $leaf = Split-Path -Leaf $full; $guid = [guid]::Empty
    if (-not $leaf.StartsWith($Prefix, [StringComparison]::Ordinal) -or -not [guid]::TryParseExact($leaf.Substring($Prefix.Length), 'N', [ref]$guid) -or
        -not [string]::Equals((Split-Path -Parent $full).TrimEnd('\','/'), $temp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup refused a path outside its unique test temp directory.' }
    if (@(Get-ChildItem -LiteralPath $full -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Cleanup refused a tree containing a reparse point.' }
    Remove-Item -LiteralPath $full -Recurse -Force
}

$workerSource = @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Security;

public static class AppContainerNetworkWorker {
    static string error(Exception e) { return e.GetType().Name + ": " + e.Message; }
    static bool TryConnect(int port, int timeout) {
        try { using (var c = new TcpClient()) { var ar = c.BeginConnect(IPAddress.Loopback, port, null, null); using (ar.AsyncWaitHandle) { if (!ar.AsyncWaitHandle.WaitOne(timeout)) return false; c.EndConnect(ar); } c.GetStream().WriteByte(0x41); return true; } }
        catch { return false; }
    }
    static bool HostWriteDenied(string path) {
        try { File.AppendAllText(path, "forbidden"); return false; }
        catch (UnauthorizedAccessException) { return true; }
        catch (SecurityException) { return true; }
    }
    public static int Main(string[] a) {
        if (a.Length != 8) return 10;
        bool managedWrite=false, hostDenied=false, mutexNew=false, dns=false, https=false, httpTimeout=false, toHost=false, localListen=false;
        string dnsError="", httpsStatus="", timeoutError="", loopError="";
        try { File.WriteAllText(a[0], "managed-write"); managedWrite=true; } catch {}
        hostDenied=HostWriteDenied(a[1]);
        try { using (var m=new Mutex(true,a[2],out mutexNew)) {} } catch {}
        try { dns=System.Net.Dns.GetHostAddresses("example.com").Length>0; } catch(Exception e) { dnsError=error(e); }
        try { var request=(HttpWebRequest)WebRequest.Create("https://example.com/"); request.Method="GET"; request.Proxy=null; request.Timeout=12000; request.ReadWriteTimeout=12000; using(var response=(HttpWebResponse)request.GetResponse()) { httpsStatus=((int)response.StatusCode).ToString(); } } catch(WebException e) { if(e.Response is HttpWebResponse) httpsStatus=((int)((HttpWebResponse)e.Response).StatusCode).ToString(); else httpsStatus="error: "+error(e); } catch(Exception e) { httpsStatus="error: "+error(e); }
        https=httpsStatus.Length>0 && !httpsStatus.StartsWith("error:");
        // The host listener accepts this TCP connection but deliberately sends no HTTP response.
        try { var req=(HttpWebRequest)WebRequest.Create("http://127.0.0.1:"+a[3]+"/stall"); req.Proxy=null; req.Timeout=1800; req.ReadWriteTimeout=1800; using(var resp=req.GetResponse()) {} }
        catch(WebException e) { httpTimeout=e.Status==WebExceptionStatus.Timeout; timeoutError=e.Status.ToString(); }
        catch(Exception e) { timeoutError=error(e); }
        toHost=TryConnect(Int32.Parse(a[3]),2500);
        TcpListener listener=null; IAsyncResult accept=null;
        try {
            listener=new TcpListener(IPAddress.Loopback,0); listener.Start();
            File.WriteAllText(a[4],((IPEndPoint)listener.LocalEndpoint).Port.ToString());
            accept=listener.BeginAcceptTcpClient(null,null);
        } catch(Exception e) { loopError=error(e); }
        // One brief accept window, then publish evidence and exit.
        try { File.WriteAllText(a[5], "ready"); } catch {}
        if(accept!=null && accept.AsyncWaitHandle.WaitOne(5000)) { try { using(var c=listener.EndAcceptTcpClient(accept)) { c.ReceiveTimeout=2000; int b=c.GetStream().ReadByte(); localListen=b==0x42; } } catch(Exception e) { loopError=error(e); } }
        if(listener!=null) listener.Stop();
        try { File.WriteAllText(a[6], "{\"managedWrite\":"+managedWrite.ToString().ToLower()+",\"hostWriteDenied\":"+hostDenied.ToString().ToLower()+",\"mutexCreatedNew\":"+mutexNew.ToString().ToLower()+",\"dns\":"+dns.ToString().ToLower()+",\"dnsError\":\""+dnsError.Replace("\\","\\\\").Replace("\"","\\\"")+"\",\"https\":"+https.ToString().ToLower()+",\"httpsStatus\":\""+httpsStatus.Replace("\"","\\\"")+"\",\"httpTimeout\":"+httpTimeout.ToString().ToLower()+",\"timeoutError\":\""+timeoutError+"\",\"appContainerToHost\":"+toHost.ToString().ToLower()+",\"acLoopbackListen\":"+localListen.ToString().ToLower()+",\"loopbackError\":\""+loopError.Replace("\"","\\\"")+"\"}"); } catch { return 12; }
        return 0;
    }
}
'@

# Use a native background thread instead of a PowerShell scriptblock callback:
# callback threads have no guaranteed PowerShell runspace. The marker is written
# only after a complete HTTP header was read, proving the controlled request
# reached this host listener before it deliberately withholds the response.
$listenerSource = @'
using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public static class AppContainerStalledHttpListener {
    public static void Start(TcpListener listener, string marker) {
        var thread=new Thread(new ParameterizedThreadStart(Run)); thread.IsBackground=true;
        thread.Start(new object[]{listener,marker});
    }
    static void Run(object state) {
        var values=(object[])state; TcpListener listener=(TcpListener)values[0]; string marker=(string)values[1]; TcpClient client=null;
        try {
            client=listener.AcceptTcpClient(); client.ReceiveTimeout=5000;
            var stream=client.GetStream(); int matched=0; int total=0; int value;
            byte[] ending=new byte[]{13,10,13,10};
            while(total<16384 && (value=stream.ReadByte())>=0) {
                total++;
                if(value==ending[matched]) matched++; else matched=value==13?1:0;
                if(matched==ending.Length) { File.WriteAllText(marker,"complete-http-headers"); break; }
            }
            Thread.Sleep(4000);
        } catch {} finally { if(client!=null) client.Close(); }
    }
}
'@
Add-Type -TypeDefinition $listenerSource -ErrorAction Stop

try {
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $script:root = New-AppContainerProbeFixtureRoot
    $id = (Split-Path -Leaf $script:root).Substring('aistick-ac-probe-'.Length)
    $script:hostRoot = Join-Path $temp ('aistick-ac-host-probe-' + [guid]::NewGuid().ToString('N'))
    $app = Join-Path $script:root 'app'; $stick = Join-Path $script:root 'stick'; $runtime = Join-Path $script:root 'runtime'
    foreach ($d in @($app,$stick,$runtime,$script:hostRoot)) { [IO.Directory]::CreateDirectory($d) | Out-Null }
    Protect-HostDirectory $script:hostRoot
    $sentinel = Join-Path $script:hostRoot 'host-sentinel.txt'; [IO.File]::WriteAllText($sentinel,'host sentinel')
    $sentinelHash = Get-Hash $sentinel
    $hostListener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $hostListener.Start()
    $hostPort = $hostListener.LocalEndpoint.Port
    $httpAcceptedPath=Join-Path $script:hostRoot 'http-listener-accepted.txt'
    [AppContainerStalledHttpListener]::Start($hostListener,$httpAcceptedPath)
    $workerExe = Join-Path $app 'cc-switch.exe'
    Add-Type -TypeDefinition $workerSource -OutputType ConsoleApplication -OutputAssembly $workerExe -ErrorAction Stop
    $writePath=Join-Path $stick 'managed.txt'; $mutexName='AiStick.AppContainer.Network.'+$id
    $created=$false; $script:mutex=New-Object Threading.Mutex($true,$mutexName,[ref]$created)
    Assert-Check $created 'The unique test mutex was unexpectedly occupied.'
    $acPortPath=Join-Path $stick 'ac-port.txt'; $readyPath=Join-Path $stick 'ready.txt'; $resultPath=Join-Path $stick 'result.json'
    $fixturePath=Join-Path $script:root 'fixture.json'
    $fixture=[ordered]@{ Root=$script:root; Exe=$workerExe; StickRoot=$stick; RuntimeRoot=$runtime; Environment=[ordered]@{HOME=$stick;USERPROFILE=$stick;APPDATA=$stick;LOCALAPPDATA=$stick;TEMP=$stick;TMP=$stick}; Arguments=@($writePath,$sentinel,$mutexName,[string]$hostPort,$acPortPath,$readyPath,$resultPath,$httpAcceptedPath) }
    [IO.File]::WriteAllText($fixturePath,(ConvertTo-Json $fixture -Depth 8),(New-Object Text.UTF8Encoding($false)))
    $fixture=Read-AppContainerFixture $fixturePath
    $script:state=Start-AppContainerProbeProcess -Fixture $fixture -NetworkMode InternetClient
    # The worker performs DNS and HTTPS before creating its AppContainer listener.
    # Coordinate against the same bounded worker budget instead of assuming the
    # listener appears within eight seconds on a slow but otherwise valid network.
    $connectDeadline=[DateTime]::UtcNow.AddSeconds(40)
    while (-not (Test-Path $acPortPath) -and [DateTime]::UtcNow -lt $connectDeadline) { Start-Sleep -Milliseconds 100 }
    if (Test-Path $acPortPath) {
        $port=[int][IO.File]::ReadAllText($acPortPath)
        $client=New-Object Net.Sockets.TcpClient
        try { $ar=$client.BeginConnect([Net.IPAddress]::Loopback,$port,$null,$null); if ($ar.AsyncWaitHandle.WaitOne(2500)) { $client.EndConnect($ar); $client.GetStream().WriteByte(0x42); $script:hostToAcSucceeded=$true } }
        catch { }
        finally { $client.Close() }
    }
    $wait=Wait-AppContainerProbeProcess -State $script:state -TimeoutSeconds 60
    Assert-Check $wait.Completed 'Network probe worker timed out.'
    Assert-Check (Test-Path $resultPath) 'Network probe worker did not publish evidence.'
    $result=[IO.File]::ReadAllText($resultPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
    Record-Check 'real suspended token contains internetClient capability' { Assert-Check $script:state.NetworkCapabilitiesGranted 'Network mode did not report enabled.' }
    Record-Check 'synthetic authorized-root write succeeds' { Assert-Check ($result.managedWrite -and (Test-Path $writePath)) 'Managed write failed.' }
    Record-Check 'host-only sentinel write is denied and unchanged' { Assert-Check ($result.hostWriteDenied -and (Get-Hash $sentinel) -ceq $sentinelHash) 'Host sentinel changed or write was not denied.' }
    Record-Check 'same-named host mutex remains isolated' { Assert-Check $result.mutexCreatedNew 'Worker acquired host mutex namespace.' }
    Record-Check 'DNS resolution is actually attempted' { Assert-Check ($result.dns -or $result.dnsError) 'No DNS result or failure evidence.' }
    Record-Check 'HTTPS request reaches a certificate-validated HTTP response' { Assert-Check $result.https ("HTTPS failed: {0}" -f $result.httpsStatus) }
    Record-Check 'HTTP request to the controlled stalled endpoint times out' { Assert-Check ($result.httpTimeout -and (Test-Path $httpAcceptedPath)) ("The stalled server did not prove a response timeout (accepted={0}, result={1})." -f (Test-Path $httpAcceptedPath),$result.timeoutError) }
    Record-Check 'AppContainer to host loopback TCP was actually measured' { Assert-Check ($null -ne $result.PSObject.Properties['appContainerToHost']) 'No outbound loopback result was published.' }
    Record-Check 'AppContainer listener publishes a real port' { Assert-Check (Test-Path $acPortPath) 'AppContainer worker did not publish its bound port.' }
    Record-Check 'ordinary host to AppContainer loopback TCP' { Assert-Check $script:hostToAcSucceeded 'Host process could not connect to AppContainer listener.' }
    Record-Check 'AppContainer listener received host payload' { Assert-Check $result.acLoopbackListen 'Worker did not receive host payload.' }
    Write-Host ("Observed network: DNS={0}; HTTPS={1}; container-to-host-loopback={2}; host-to-container-loopback={3}" -f $result.dns,$result.https,$result.appContainerToHost,$script:hostToAcSucceeded)
    Complete-AppContainerProbeProcess -State $script:state; $script:state=$null
    $hostListener.Stop()
} catch {
    $script:failed++; Write-Host ("FAIL network/loopback setup - {0}" -f $_.Exception.Message)
} finally {
    if ($script:state) { try { Complete-AppContainerProbeProcess -State $script:state; $script:state=$null } catch { $script:cleanupSafe=$false; Write-Host 'CLEANUP FAILED: preserving synthetic fixture for inspection.' } }
    if ($script:mutex) { try { $script:mutex.ReleaseMutex() } catch {}; $script:mutex.Dispose() }
    if ($hostListener) { try { $hostListener.Stop() } catch {} }
    if ($script:cleanupSafe) {
        try { Remove-OwnedTree $script:hostRoot 'aistick-ac-host-probe-' } catch { $script:cleanupSafe=$false; Write-Host ("CLEANUP FAILED: {0}" -f $_.Exception.Message) }
        if ($script:cleanupSafe) { try { Remove-OwnedTree $script:root 'aistick-ac-probe-' } catch { $script:cleanupSafe=$false; Write-Host ("CLEANUP FAILED: {0}" -f $_.Exception.Message) } }
    }
}
Write-Host ("`nAppContainer network/loopback checks: {0} passed, {1} failed." -f $script:passed,$script:failed)
if ($script:failed -or -not $script:cleanupSafe) { exit 1 }
