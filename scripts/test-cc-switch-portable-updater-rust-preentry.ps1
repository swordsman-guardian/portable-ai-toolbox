[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-native-update-session.ps1')

$root=$null;$state=$null;$safeToRemove=$false
try {
    $adapterRoot=Join-Path $PSScriptRoot '..\tools\cc-switch-adapter'
    $shim=Join-Path $adapterRoot 'cc-switch-portable-updater-shim.dll'
    $noop=Join-Path $adapterRoot 'cc-switch-portable-update-noop.exe'
    $manifest=Get-Content -LiteralPath (Join-Path $adapterRoot 'cc-switch-portable-updater-shim.manifest.json') -Raw | ConvertFrom-Json -ErrorAction Stop
    if((Get-FileHash -LiteralPath $shim -Algorithm SHA256).Hash -ne $manifest.dllSha256 -or (Get-FileHash -LiteralPath $noop -Algorithm SHA256).Hash -ne $manifest.noopExeSha256){throw 'Portable shim package does not match its manifest.'}
    $rustc=(Get-Command rustc.exe -ErrorAction Stop).Source
    $root=New-AppContainerProbeFixtureRoot
    $app=Join-Path $root 'app';$stick=Join-Path $root 'stick';$runtime=Join-Path $root 'runtime';$updates=Join-Path $runtime 'updates'
    foreach($dir in @($app,$stick,$runtime,$updates)){[IO.Directory]::CreateDirectory($dir)|Out-Null}
    [IO.File]::WriteAllText((Join-Path $app 'portable.ini'),'portable=true`n',(New-Object Text.UTF8Encoding($false)))
    $source=@'
use std::{env,fs,process::Command};

unsafe extern "C" fn before_main() {
    let current=env::current_exe();
    let canonical=current.as_ref().map(|p|fs::canonicalize(p).is_ok()).unwrap_or(false);
    let output=env::args_os().nth(1).expect("result path");
    let body=format!("current_exe_ok={} canonicalize_ok={}\n",current.is_ok(),canonical);
    let _=fs::write(output,body.as_bytes());
}

#[used]
#[link_section=".CRT$XCU"]
static BEFORE_MAIN: unsafe extern "C" fn()=before_main;

fn main() {
    if env::var_os("CCSU_TEST_CHILD").is_some() { let _=Command::new("cmd.exe").spawn(); }
}
'@
    $sourcePath=Join-Path $runtime 'rust-preentry-probe.rs';$exe=Join-Path $app 'cc-switch.exe';$resultPath=Join-Path $stick 'rust-preentry-result.txt'
    [IO.File]::WriteAllText($sourcePath,$source,(New-Object Text.UTF8Encoding($false)))
    $build=Start-Process -FilePath $rustc -ArgumentList @('--edition=2021',$sourcePath,'-o',$exe) -Wait -PassThru -WindowStyle Hidden
    if($build.ExitCode -ne 0 -or -not [IO.File]::Exists($exe)){throw 'Minimal Rust constructor probe did not build.'}
    $fixture=[ordered]@{Root=$root;Exe=$exe;StickRoot=$stick;RuntimeRoot=$runtime;Environment=[ordered]@{HOME=$stick;USERPROFILE=$stick;APPDATA=$stick;LOCALAPPDATA=$stick;TEMP=$runtime;TMP=$runtime};Arguments=@($resultPath)}
    $fixturePath=Join-Path $root 'fixture.json';[IO.File]::WriteAllText($fixturePath,(ConvertTo-Json $fixture -Depth 5),(New-Object Text.UTF8Encoding($false)))
    $loaded=Read-AppContainerFixture -Path $fixturePath
    $package=[pscustomobject]@{Version='v3.20.4';AppDirectory=$app;ArchiveVerified=$true;ExtractedFilesVerified=$true;Source='Synthetic'}
    $launch=Start-CcSwitchNativeUpdateSession -Fixture $loaded -Package $package -NetworkMode None
    $state=$launch.State
    $wait=Wait-AppContainerProbeProcess -State $state -TimeoutSeconds 20
    if(-not $wait.Completed -or $wait.ExitCode -ne 0 -or -not [IO.File]::Exists($resultPath)){throw 'Rust constructor probe did not finish successfully.'}
    $result=[IO.File]::ReadAllText($resultPath,[Text.Encoding]::ASCII).Trim()
    if($result -cne 'current_exe_ok=true canonicalize_ok=true'){throw ('Rust pre-main canonicalize did not succeed: '+$result)}
    $marker=Join-Path $updates 'finalpath-owned-fallback.hit'
    if(-not [IO.File]::Exists($marker)){throw 'The Rust constructor did not trigger the owned executable final-path adapter.'}
    Write-Output 'PASS: Rust .CRT$XCU constructor called std::fs::canonicalize before main; pre-entry AppContainer shim enabled only the verified owned executable fallback.'
    Complete-AppContainerProbeProcess -State $state;$state=$null;$safeToRemove=$true
} finally {
    if($state){try{Complete-AppContainerProbeProcess -State $state;$safeToRemove=$true}catch{Write-Warning 'Preserving the owned Rust pre-entry fixture because cleanup could not be verified.'}}
    if($root -and $safeToRemove){$full=[IO.Path]::GetFullPath($root).TrimEnd('\');$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\');$entry=Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue;if($entry -and -not ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -and [string]::Equals((Split-Path -Parent $full),$temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $full) -match '^aistick-ac-probe-[0-9a-f]{32}$' -and (Test-Path -LiteralPath (Join-Path $full '.aistick-ac-probe') -PathType Leaf)){Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue}}
}
