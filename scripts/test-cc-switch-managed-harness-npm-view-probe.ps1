[CmdletBinding()]
param([string]$UsbRoot='E:\',[ValidateRange(20,120)][int]$TimeoutSeconds=75,[ValidateRange(15,30)][int]$MetadataTimeoutSeconds=25)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-context.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-harness-runtime.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-isolated-managed-owner.ps1')

$usb=[IO.Path]::GetFullPath($UsbRoot)
$expectedVolume=Get-CcSwitchHarnessVolumeIdentity -Path $usb
$sourceStatus=Get-CcSwitchHarnessRuntimeStatus -StickRoot $usb
if(-not $sourceStatus.Ready){throw 'Verified USB Node/npm runtime is incomplete.'}
$root=New-AppContainerProbeFixtureRoot
$state=$null
$complete=$false
$preserve=$true
$resultPath=$null
try {
    $app=Join-Path $root 'app'
    $runtime=Join-Path $root 'runtime'
    $stick=Join-Path $root 'stick'
    $session=Join-Path $runtime 'session'
    $harness=Join-Path $root 'harness'
    $slotId='2.1.281'
    $slot=Join-Path $harness ('slots\'+$slotId)
    foreach($dir in @($app,$runtime,$stick,$session,$harness,$slot,(Join-Path $harness 'state\npm-data\cache'),(Join-Path $harness 'state\npm-data\config'))){[IO.Directory]::CreateDirectory($dir)|Out-Null}
    $volumeAtStart=Get-CcSwitchHarnessVolumeIdentity -Path $usb
    if(-not(Test-CcSwitchHarnessVolumeIdentity -Expected $volumeAtStart -Actual (Get-CcSwitchHarnessVolumeIdentity -Path $usb))){throw 'USB volume changed before the read-only runtime copy.'}
    Copy-CcSwitchManagedHarnessTree -Source $sourceStatus.RuntimeRoot -Destination (Join-Path $runtime 'node')
    if(-not(Test-CcSwitchHarnessVolumeIdentity -Expected $expectedVolume -Actual (Get-CcSwitchHarnessVolumeIdentity -Path $usb))){throw 'USB volume identity changed during the read-only runtime copy.'}
    foreach($configName in @('user.npmrc','global.npmrc')){[IO.File]::WriteAllText((Join-Path $harness ('state\npm-data\config\'+$configName)),'',(New-Object Text.UTF8Encoding($false)))}
    $context=New-CcSwitchPortableContext -StickRoot $stick -SessionRoot $session -HarnessIds @('claude')
    $null=Initialize-CcSwitchPortableContext -Context $context
    $environment=Get-CcSwitchPortableEnvironment -Context $context
    $system32=Join-Path $env:SystemRoot 'System32'
    $environment['PATH']=@($slot,(Join-Path $runtime 'node'),$system32) -join ';'
    $environment['npm_config_prefix']=$slot
    $environment['npm_config_cache']=Join-Path $harness 'state\npm-data\cache'
    $environment['npm_config_userconfig']=Join-Path $harness 'state\npm-data\config\user.npmrc'
    $environment['npm_config_globalconfig']=Join-Path $harness 'state\npm-data\config\global.npmrc'
    $environment['npm_config_registry']='https://registry.npmjs.org/'
    $environment['NODE_OPTIONS']='--preserve-symlinks --preserve-symlinks-main'

    $node=Join-Path $runtime 'node\node.exe'
    $npmCli=Join-Path $runtime 'node\node_modules\npm\bin\npm-cli.js'
    $where=Join-Path $system32 'where.exe'
    $worker=Join-Path $runtime 'npm-resolution-probe.js'
    $resultPath=Join-Path $stick 'npm-resolution-probe-result.json'
    [IO.File]::Copy($node,(Join-Path $app 'cc-switch.exe'),$false)
    $js=@'
const cp=require('node:child_process');
const fs=require('node:fs');
const [npmCli,nodeExe,whereExe,resultPath,metadataTimeoutText]=process.argv.slice(2);
const cwd=process.cwd(),baseEnv={...process.env},metadataTimeoutMs=Number(metadataTimeoutText);
const partial={schema:1,phase:'starting',workdirKind:'owned app directory',registry:'https://registry.npmjs.org/',package:'@anthropic-ai/claude-code@latest',operation:'npm view version --prefer-online',nodeOptionsPresent:!!baseEnv.NODE_OPTIONS,pathEntryCount:String(baseEnv.PATH||'').split(';').length,installRequested:false,modelRequestMade:false};
function save(){fs.writeFileSync(resultPath,JSON.stringify(partial,null,2),'utf8')}
function summarize(text){return String(text).split(/\r?\n/).filter(line=>/(npm error|npm ERR!|ENOTFOUND|ECONN|EHOST|ETIMEDOUT|CERT_|TLS|proxy|registry|network)/i.test(line)).slice(0,12).map(line=>line.replace(/(https?:\/\/)[^/@\s]+:[^/@\s]+@/ig,'$1[REDACTED]'))}
function run(label,command,args,env,timeoutMs,onAfterSpawn){return new Promise(resolve=>{let out='',err='',spawnError=null,didTimeout=false,settled=false,exitCode=null,signal=null;const started=Date.now();let child;const finish=()=>{if(settled)return;settled=true;clearTimeout(timer);resolve({label,exitCode,signal:signal||null,spawnError,spawnReturned:!!child,childPid:child&&Number.isInteger(child.pid)?child.pid:null,stdout:out.trim(),diagnosticLines:summarize(err),timedOut:didTimeout,elapsedMs:Date.now()-started,timeoutMs})};const timer=setTimeout(()=>{didTimeout=true;try{child.kill()}catch{};try{child.stdout.destroy()}catch{};try{child.stderr.destroy()}catch{};finish()},timeoutMs);try{child=cp.spawn(command,args,{cwd,env,windowsHide:true,stdio:['ignore','pipe','pipe']});if(typeof onAfterSpawn==='function')onAfterSpawn(!!child.pid,child.pid||null);child.stdout.on('data',b=>{if(out.length<16384)out+=b.toString('utf8')});child.stderr.on('data',b=>{if(err.length<16384)err+=b.toString('utf8')});child.on('error',e=>{spawnError={code:e.code||null,errno:e.errno||null,syscall:e.syscall||null};try{child.stdout.destroy()}catch{};try{child.stderr.destroy()}catch{};finish()});child.on('exit',(code,childSignal)=>{exitCode=code;signal=childSignal;setTimeout(()=>{try{child.stdout.destroy()}catch{};try{child.stderr.destroy()}catch{};finish()},200)});child.on('close',(code,childSignal)=>{exitCode=code;signal=childSignal;finish()})}catch(e){spawnError={code:e.code||null,errno:e.errno||null,syscall:e.syscall||null};finish()}})}
function normalizeWhere(result){const lines=String(result.stdout||'').split(/\r?\n/).map(x=>x.trim()).filter(Boolean);return {exitCode:result.exitCode,timedOut:result.timedOut,elapsedMs:result.elapsedMs,spawnError:result.spawnError,candidates:lines.map(p=>({leaf:p.split(/[\\/]/).pop(),extension:(p.match(/\.[^.\\/]+$/)||[''])[0].toLowerCase(),insideManagedNode:p.toLowerCase().includes('\\runtime\\node\\')}))}}
(async()=>{
  partial.phase='where-without-PATHEXT-before-spawn';save();
  const noExtEnv={...baseEnv};delete noExtEnv.PATHEXT;
  partial.whereWithoutPathext=normalizeWhere(await run('where-npm-no-pathext',whereExe,['npm'],noExtEnv,10000,(pid,childPid)=>{partial.phase=pid?'where-without-PATHEXT-afterSpawn':'where-without-PATHEXT-spawn-no-pid';partial.whereWithoutPathextSpawnPid=childPid;save()}));save();
  partial.phase='where-with-standard-PATHEXT';
  const extEnv={...baseEnv,PATHEXT:'.COM;.EXE;.BAT;.CMD'};
  partial.whereWithStandardPathext=normalizeWhere(await run('where-npm-standard-pathext',whereExe,['npm'],extEnv,10000,(pid,childPid)=>{partial.phase=pid?'where-standard-PATHEXT-afterSpawn':'where-standard-PATHEXT-spawn-no-pid';partial.whereWithStandardPathextSpawnPid=childPid;save()}));save();
  partial.phase='absolute-npm-cli-metadata';
  partial.directNpmCli=await run('absolute-node-npm-cli',nodeExe,['--preserve-symlinks','--preserve-symlinks-main',npmCli,'view','@anthropic-ai/claude-code@latest','version','--prefer-online'],baseEnv,metadataTimeoutMs);save();
  partial.phase='complete';save();
})().catch(e=>{partial.phase='worker-error';partial.workerFailureCode=e.code||null;partial.workerFailureName=e.name||null;try{save()}catch{};process.exitCode=2});
'@
    [IO.File]::WriteAllText($worker,$js,(New-Object Text.UTF8Encoding($false)))
    $fixture=New-CcSwitchIsolatedFixtureRecord -Root $root -Exe (Join-Path $app 'cc-switch.exe') -StickRoot $stick -RuntimeRoot $runtime -ManagedHarnessRoot $harness -Environment $environment -Arguments @($worker,$npmCli,$node,$where,$resultPath,[string]($MetadataTimeoutSeconds*1000))
    $fixturePath=Join-Path $root 'fixture.json'
    [IO.File]::WriteAllText($fixturePath,(ConvertTo-Json -InputObject $fixture -Depth 6),(New-Object Text.UTF8Encoding($false)))
    $validated=Read-AppContainerFixture -Path $fixturePath
    Write-Output ([pscustomobject]@{Status='Probe fixture ready';FixtureRoot=$root;WorkingDirectory=(Join-Path $root 'app');ResultPath=$resultPath;NodeVersion=$sourceStatus.NodeVersion;NpmVersion=$sourceStatus.NpmVersion;NetworkMode='InternetClient';ExpectedMetadataTimeoutSeconds=$MetadataTimeoutSeconds;InstallRequested=$false;ModelRequestMade=$false})
    $state=Start-AppContainerProbeProcess -Fixture $validated -NetworkMode InternetClient
    Write-Output ([pscustomobject]@{Status='Node/npm resolution worker started';ProcessId=[int]$state.ProcessId;FixtureRoot=$root;ResultPath=$resultPath;WorkingDirectory=(Join-Path $root 'app')})
    $wait=Wait-AppContainerProbeProcess -State $state -TimeoutSeconds $TimeoutSeconds
    if(-not $wait.Completed){throw 'AppContainer Node/npm resolution worker exceeded its outer time limit; partial result retained.'}
    if($wait.ExitCode -ne 0 -or -not [IO.File]::Exists($resultPath)){throw ('AppContainer Node/npm resolution worker exited with code '+$wait.ExitCode+'; partial result retained.')}
    $report=[IO.File]::ReadAllText($resultPath,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop
    if($report.phase -cne 'complete'){throw 'AppContainer worker returned a partial report; fixture retained.'}
    Complete-AppContainerProbeProcess -State $state
    $state=$null
    $complete=$true
    Write-Output ([pscustomobject]@{ProcessExitCode=$wait.ExitCode;FixtureRoot=$root;Result=$report;InstallRequested=$false;ModelRequestMade=$false})
    $preserve=$false
} catch {
    Write-Warning ('Probe failed; fixture retained for diagnosis: '+$root+'. '+$_.Exception.Message)
    if($resultPath -and [IO.File]::Exists($resultPath)){
        try{$partial=[IO.File]::ReadAllText($resultPath,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop;Write-Output ([pscustomobject]@{PartialResultPath=$resultPath;PartialPhase=$partial.phase;WhereWithoutPathext=$partial.whereWithoutPathext;WhereWithStandardPathext=$partial.whereWithStandardPathext;DirectNpmCli=$partial.directNpmCli})}catch{}
    }
    throw
} finally {
    if($state){try{Complete-AppContainerProbeProcess -State $state;$state=$null}catch{Write-Warning ('Owned probe cleanup failed; fixture remains at '+$root);$preserve=$true}}
    if($complete -and -not $preserve -and [IO.Directory]::Exists($root)){
        $full=[IO.Path]::GetFullPath($root).TrimEnd('\','/')
        $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        $parsed=[guid]::Empty
        if([string]::Equals((Split-Path -Parent $full).TrimEnd('\','/'),$temp,[StringComparison]::OrdinalIgnoreCase) -and [guid]::TryParseExact(((Split-Path -Leaf $full)-replace '^aistick-ac-probe-',''),'N',[ref]$parsed)){
            Assert-AppContainerProbePlainTree -Path $root -Boundary $temp
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
        }
    } elseif($preserve -and [IO.Directory]::Exists($root)) { Write-Output ('Probe fixture retained: '+$root) }
}
