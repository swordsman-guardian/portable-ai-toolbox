[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')

# This is a bounded direct-connectivity diagnostic. It never uses credentials
# or a real CC Switch profile; the current provider base URL gets only an unauthenticated GET.
$source = @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Security.Authentication;
using System.Text;
using System.Threading;
using System.Diagnostics;
using System.Security;

public static class AppContainerEgressWorker {
    static string Q(string s) {
        if (s == null) return "null";
        return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n") + "\"";
    }
    static string Error(Exception e) { return e.GetType().Name + ": " + e.Message; }
    static string One(string host, string path) {
        string dns="not-run", tcp="not-run", tls="not-run", http="not-run";
        string ip="", family="", families="", dnsError="", tcpError="", tlsError="", httpError="";
        var timer=Stopwatch.StartNew();
        try {
            var ar=Dns.BeginGetHostAddresses(host,null,null);
            if (!ar.AsyncWaitHandle.WaitOne(3000)) dns="timeout";
            else {
                var ips=Dns.EndGetHostAddresses(ar);
                if (ips.Length==0) dns="empty";
                else {
                    dns="ok";
                    var seen=new System.Collections.Generic.List<string>();
                    foreach(var candidate in ips) { string f=candidate.AddressFamily==AddressFamily.InterNetwork?"IPv4":"IPv6"; if(!seen.Contains(f)) seen.Add(f); }
                    families=String.Join(",",seen.ToArray());
                    IPAddress selected=null;
                    foreach(var candidate in ips) if(candidate.AddressFamily==AddressFamily.InterNetwork) { selected=candidate; break; }
                    if(selected==null) selected=ips[0];
                    ip=selected.ToString(); family=selected.AddressFamily==AddressFamily.InterNetwork?"IPv4":"IPv6";
                }
            }
        } catch(Exception e) { dns="error"; dnsError=Error(e); }
        if (dns=="ok") {
            TcpClient client=null;
            try {
                client=new TcpClient(); var ar=client.BeginConnect(ip,443,null,null);
                if (!ar.AsyncWaitHandle.WaitOne(3000)) tcp="timeout";
                else { client.EndConnect(ar); tcp="ok"; }
                if (tcp=="ok") {
                    client.ReceiveTimeout=4000; client.SendTimeout=4000;
                    var ssl=new SslStream(client.GetStream(),false);
                    try {
                        var ta=ssl.BeginAuthenticateAsClient(host,null,SslProtocols.Tls12,false,null,null);
                        if (!ta.AsyncWaitHandle.WaitOne(4000)) tls="timeout";
                        else { ssl.EndAuthenticateAsClient(ta); tls="ok:"+ssl.SslProtocol; }
                    } finally { ssl.Dispose(); }
                }
            } catch(Exception e) { if(tcp=="ok") { tls="error"; tlsError=Error(e); } else { tcp="error"; tcpError=Error(e); } }
            finally { if(client!=null) client.Close(); }
        }
        try {
            var req=(HttpWebRequest)WebRequest.Create("https://"+host+path);
            req.Method="GET"; req.Proxy=null; req.AllowAutoRedirect=false;
            req.Timeout=5000; req.ReadWriteTimeout=5000;
            using(var resp=(HttpWebResponse)req.GetResponse()) { http="status:"+(int)resp.StatusCode; }
        } catch(WebException e) {
            if(e.Response is HttpWebResponse) { using(var resp=(HttpWebResponse)e.Response) { http="status:"+(int)resp.StatusCode; } }
            else { http=e.Status==WebExceptionStatus.Timeout?"timeout":"error"; httpError=Error(e); }
        } catch(Exception e) { http="error"; httpError=Error(e); }
        timer.Stop();
        return "{\"url\":"+Q("https://"+host+path)+",\"host\":"+Q(host)+",\"dns\":"+Q(dns)+",\"dnsFamilies\":"+Q(families)+",\"tcpAddressFamily\":"+Q(family)+",\"dnsError\":"+Q(dnsError)+",\"tcp443\":"+Q(tcp)+",\"tcpError\":"+Q(tcpError)+",\"tls\":"+Q(tls)+",\"tlsError\":"+Q(tlsError)+",\"http\":"+Q(http)+",\"httpError\":"+Q(httpError)+",\"elapsedMs\":"+timer.ElapsedMilliseconds+"}";
    }
    public static int Main(string[] args) {
        if(args.Length!=4) return 10;
        ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;
        bool writeAllowed=false, hostWriteDenied=false;
        if(args[0]=="appcontainer") {
            try { File.WriteAllText(args[2],"appcontainer-write-ok"); writeAllowed=true; } catch {}
            try { File.AppendAllText(args[3],"forbidden"); }
            catch(UnauthorizedAccessException) { hostWriteDenied=true; }
            catch(SecurityException) { hostWriteDenied=true; }
        }
        string[] hosts={"learn.microsoft.com","www.microsoft.com","github.com","api.github.com","example.com","token-plan.cn-beijing.maas.aliyuncs.com"};
        string[] paths={"/","/","/","/","/","/apps/anthropic"};
        var sb=new StringBuilder(); sb.Append("{\"mode\":").Append(Q(args[0])).Append(",\"proxyExplicitlyNull\":true,\"writeAllowed\":").Append(writeAllowed?"true":"false").Append(",\"hostWriteDenied\":").Append(hostWriteDenied?"true":"false").Append(",\"endpoints\":[");
        for(int i=0;i<hosts.Length;i++) { if(i>0) sb.Append(','); sb.Append(One(hosts[i],paths[i])); }
        sb.Append("]}");
        try { File.WriteAllText(args[1],sb.ToString(),new UTF8Encoding(false)); return 0; }
        catch { return 11; }
    }
}
'@

$root = $null
$state = $null
$cleanupSafe = $true
$script:hostRoot = $null
$exitCode = 1
function Write-EgressFailureReport([string]$Class, [string]$Message) {
    try {
        $failureReport=[pscustomobject]@{CreatedUtc=[DateTime]::UtcNow.ToString('o');DiagnosticStatus='failed';FailureClass=$Class;Error=$Message;Diagnostic='Unauthenticated direct connectivity, including provider base URL; no key or model request.'}
        [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\appcontainer-egress-latest.json'),($failureReport|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($true)))
    } catch {}
}
try {
    $root = New-AppContainerProbeFixtureRoot
    $app = Join-Path $root 'app'; $stick = Join-Path $root 'stick'; $runtime = Join-Path $root 'runtime'
    foreach ($dir in @($app,$stick,$runtime)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
    $script:hostRoot=Join-Path $root 'host-boundary'
    [IO.Directory]::CreateDirectory($script:hostRoot) | Out-Null
    $acl=[IO.Directory]::GetAccessControl($script:hostRoot)
    $acl.SetAccessRuleProtection($true,$false)
    foreach($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleAll($rule) }
    foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),(New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544'))) ) {
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,[Security.AccessControl.FileSystemRights]::FullControl,([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($rule)
    }
    [IO.Directory]::SetAccessControl($script:hostRoot,$acl)
    $sentinel=Join-Path $script:hostRoot 'host-sentinel.txt'
    [IO.File]::WriteAllText($sentinel,'host sentinel')
    $hashAlg=[Security.Cryptography.SHA256]::Create()
    try { $sentinelHash=[BitConverter]::ToString($hashAlg.ComputeHash([IO.File]::ReadAllBytes($sentinel))).Replace('-','') } finally { $hashAlg.Dispose() }
    $exe = Join-Path $app 'cc-switch.exe'
    Add-Type -TypeDefinition $source -OutputType ConsoleApplication -OutputAssembly $exe -ErrorAction Stop
    $hostResultPath = Join-Path $root 'host-result.json'
    $containerResultPath = Join-Path $stick 'container-result.json'
    $proc = Start-Process -FilePath $exe -ArgumentList @('host',$hostResultPath,'-','-') -PassThru -WindowStyle Hidden
    if (-not $proc.WaitForExit(100000)) { try { $proc.Kill() } catch {}; throw 'Host diagnostic exceeded its 100-second deadline.' }
    if ($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $hostResultPath)) { throw ('Host diagnostic failed with exit code {0}.' -f $proc.ExitCode) }

    $fixturePath = Join-Path $root 'fixture.json'
    $fixture = [ordered]@{
        Root=$root; Exe=$exe; StickRoot=$stick; RuntimeRoot=$runtime
        Environment=[ordered]@{HOME=$stick;USERPROFILE=$stick;APPDATA=$stick;LOCALAPPDATA=$stick;TEMP=$stick;TMP=$stick}
        Arguments=@('appcontainer',$containerResultPath,(Join-Path $stick 'authorized-write.txt'),$sentinel)
    }
    [IO.File]::WriteAllText($fixturePath,(ConvertTo-Json $fixture -Depth 5),(New-Object Text.UTF8Encoding($false)))
    $validated = Read-AppContainerFixture -Path $fixturePath
    $state = Start-AppContainerProbeProcess -Fixture $validated -NetworkMode InternetClient
    $wait = Wait-AppContainerProbeProcess -State $state -TimeoutSeconds 100
    if (-not $wait.Completed) { throw 'AppContainer diagnostic exceeded its 100-second deadline.' }
    if ($wait.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $containerResultPath)) { throw ('AppContainer worker failed with exit code {0}.' -f $wait.ExitCode) }
    $verified = [AiStickAppContainerNative]::VerifyAppContainerToken([int]$state.ProcessId,[string]$state.AppContainerSid,$true)
    if (-not $verified) { throw 'The running worker token did not verify as AppContainer with internetClient.' }
    Complete-AppContainerProbeProcess -State $state; $state=$null

    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{NetworkCategory=[string]$_.NetworkCategory;IPv4Connectivity=[string]$_.IPv4Connectivity;IPv6Connectivity=[string]$_.IPv6Connectivity}
    })
    $firewall = Get-Service -Name MpsSvc -ErrorAction SilentlyContinue
    $hostResult = [IO.File]::ReadAllText($hostResultPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
    $containerResult = [IO.File]::ReadAllText($containerResultPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
    $sentinelHashAfter=$null
    try { $hashAlg=[Security.Cryptography.SHA256]::Create(); $sentinelHashAfter=[BitConverter]::ToString($hashAlg.ComputeHash([IO.File]::ReadAllBytes($sentinel))).Replace('-','') } finally { if($hashAlg){$hashAlg.Dispose()} }
    $validatedEndpointCount=@($containerResult.endpoints | Where-Object { $_.dns -eq 'ok' -and $_.tcp443 -eq 'ok' -and $_.tls -like 'ok:*' -and $_.http -like 'status:*' }).Count
    # Require two independent endpoints to reduce false confidence from one
    # reachable edge; 403/302 are still useful transport evidence.
    $networkPassed=$validatedEndpointCount -ge 2
    $boundaryPassed=[bool]($containerResult.writeAllowed -and (Test-Path -LiteralPath (Join-Path $stick 'authorized-write.txt')) -and $containerResult.hostWriteDenied -and ($sentinelHashAfter -ceq $sentinelHash))
    $allPassed=[bool]($verified -and $networkPassed -and $boundaryPassed)
    $report = [pscustomobject]@{
        CreatedUtc=[DateTime]::UtcNow.ToString('o')
        Diagnostic='Unauthenticated HTTPS GETs, including the current provider base URL; no API keys or model requests.'
        HostNetworkProfiles=$profiles
        FirewallServiceRunning=[bool]($firewall -and $firewall.Status -eq 'Running')
        AppContainerTokenVerified=$verified
        NetworkCapability='S-1-15-3-1 (internetClient)'
        NetworkChecksPassed=$networkPassed
        ValidatedEndpointCount=$validatedEndpointCount
        RequiredValidatedEndpoints=2
        OverallInternetReachable=$networkPassed
        FileBoundaryChecksPassed=$boundaryPassed
        AllRequiredChecksPassed=$allPassed
        NativeGuiValidation='NotTested'
        DiagnosticStatus=if($allPassed){'passed'}elseif(@($containerResult.endpoints | Where-Object { $_.http -like 'status:*' }).Count -gt 0){'partial'}else{'egress-unavailable'}
        FailureClass=if($allPassed){$null}elseif($networkPassed -eq $false){'endpoint-failure-or-network-policy'}else{'file-boundary-failure'}
        Host=$hostResult
        AppContainer=$containerResult
        AppContainerOutcome=if (@($containerResult.endpoints | Where-Object { $_.http -like 'status:*' }).Count -gt 0) { 'http-reachable' } elseif (@($containerResult.endpoints | Where-Object { $_.tcp443 -eq 'ok' -or $_.tls -like 'ok:*' }).Count -gt 0) { 'transport-only-no-http-response' } else { 'no-http-reachability-evidence' }
        Interpretation='HTTP status, including 401/403, indicates an HTTP response only; endpoint success does not establish general connectivity.'
    }
    $json = $report | ConvertTo-Json -Depth 8
    Write-Output $json
    [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\appcontainer-egress-latest.json'),$json,(New-Object Text.UTF8Encoding($true)))
    if ($allPassed) { $exitCode=0 } else { $exitCode=2 }
} catch {
    $failureClass='diagnostic-error'
    if ($_.Exception.Message -match '1260|restricted by.*policy|blocked by.*policy|Access to .*restricted') { $failureClass='blocked-by-policy' }
    Write-EgressFailureReport $failureClass $_.Exception.Message
    Write-Warning $_.Exception.Message
    $exitCode=1
} finally {
    if ($state) { try { Complete-AppContainerProbeProcess -State $state; $state=$null } catch { $cleanupSafe=$false; $exitCode=1; Write-EgressFailureReport 'cleanup-failed' $_.Exception.Message; Write-Warning ('Cleanup failed; preserving only the owned probe tree: ' + $_.Exception.Message) } }
    if ($root -and $cleanupSafe -and [IO.Directory]::Exists($root)) {
        $full=[IO.Path]::GetFullPath($root).TrimEnd('\','/')
        $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        $leaf=Split-Path -Leaf $full; $parsed=[guid]::Empty
        if (([string]::Equals((Split-Path -Parent $full).TrimEnd('\','/'),$temp,[StringComparison]::OrdinalIgnoreCase)) -and
            $leaf.StartsWith('aistick-ac-probe-',[StringComparison]::Ordinal) -and [guid]::TryParseExact($leaf.Substring('aistick-ac-probe-'.Length),'N',[ref]$parsed)) {
            $marker=Join-Path $full '.aistick-ac-probe'
            if (-not [IO.File]::Exists($marker) -or @([IO.Directory]::GetFileSystemEntries($full,'*',[IO.SearchOption]::AllDirectories) | Where-Object {
                ((Get-Item -LiteralPath $_ -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            }).Count -gt 0) {
                $exitCode=1; Write-EgressFailureReport 'cleanup-refused' 'Ownership marker is missing or the probe tree contains a reparse point.'; Write-Warning 'Cleanup refused: ownership marker is missing or the probe tree contains a reparse point.'
            } else {
                try { Remove-Item -LiteralPath $full -Recurse -Force }
                catch { $exitCode=1; Write-EgressFailureReport 'cleanup-failed' $_.Exception.Message; Write-Warning ('Owned probe tree cleanup failed: ' + $_.Exception.Message) }
            }
        } else { $exitCode=1; Write-EgressFailureReport 'cleanup-refused' 'Probe tree did not match its exact owned GUID temp boundary.'; Write-Warning 'Cleanup refused: probe tree did not match its exact owned GUID temp boundary.' }
    }
}
exit $exitCode
