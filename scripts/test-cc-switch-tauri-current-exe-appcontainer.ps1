[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')

$root = $null
$state = $null
$safeToRemove = $false
try {
    $root = New-AppContainerProbeFixtureRoot
    $app = Join-Path $root 'app'
    $stick = Join-Path $root 'stick'
    $runtime = Join-Path $root 'runtime'
    foreach ($dir in @($app,$stick,$runtime)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }

    $source = @'
use std::{env, fs, io::Write, os::windows::ffi::OsStrExt};
use std::os::windows::ffi::OsStrExt as _;
use std::ptr;
type Handle = *mut std::ffi::c_void;
#[link(name = "kernel32")]
extern "system" {
    fn CreateFileW(path: *const u16, access: u32, share: u32, sa: *mut std::ffi::c_void,
        disposition: u32, flags: u32, template: Handle) -> Handle;
    fn GetFinalPathNameByHandleW(handle: Handle, path: *mut u16, count: u32, flags: u32) -> u32;
    fn CloseHandle(handle: Handle) -> i32;
    fn GetLastError() -> u32;
}
const INVALID_HANDLE_VALUE: Handle = -1isize as Handle;
fn win32_error() -> u32 { unsafe { GetLastError() } }
fn final_path(handle: Handle, flags: u32) -> Result<(), u32> {
    let mut buffer = [0u16; 32768];
    let count = unsafe { GetFinalPathNameByHandleW(handle, buffer.as_mut_ptr(), buffer.len() as u32, flags) };
    if count == 0 { Err(win32_error()) } else { Ok(()) }
}
fn main() {
    let output = env::args_os().nth(1).expect("result path");
    let current = env::current_exe();
    let (current_ok, current_error, exe_path) = match current {
        Ok(path) => (true, String::new(), Some(path)),
        Err(error) => (false, format!("{:?}:{}", error.kind(), error.raw_os_error().unwrap_or(-1)), None),
    };
    let (canonical_ok, canonical_error) = match exe_path.as_ref().map(|path| fs::canonicalize(path)) {
        Some(Ok(_)) => (true, String::new()),
        Some(Err(error)) => (false, format!("{:?}:{}", error.kind(), error.raw_os_error().unwrap_or(-1))),
        None => (false, "current-exe-unavailable".to_string()),
    };
    let mut opened = false;
    let mut create_error = 0u32;
    let mut final_dos = false;
    let mut final_dos_error = 0u32;
    let mut final_nt = false;
    let mut final_nt_error = 0u32;
    let mut final_guid = false;
    let mut final_guid_error = 0u32;
    if let Some(path) = exe_path.as_ref() {
        let mut wide: Vec<u16> = path.as_os_str().encode_wide().collect();
        wide.push(0);
        let handle = unsafe { CreateFileW(wide.as_ptr(),0x80,0x7,ptr::null_mut(),3,0x02000000,ptr::null_mut()) };
        if handle == INVALID_HANDLE_VALUE { create_error = win32_error(); }
        else {
            opened = true;
            match final_path(handle,0) { Ok(())=>final_dos=true,Err(e)=>final_dos_error=e }
            match final_path(handle,2) { Ok(())=>final_nt=true,Err(e)=>final_nt_error=e }
            match final_path(handle,1) { Ok(())=>final_guid=true,Err(e)=>final_guid_error=e }
            unsafe { CloseHandle(handle); }
        }
    }
    let mut file = fs::File::create(output).expect("write result in authorized fixture");
    write!(file, "{{\"currentExeOk\":{},\"currentExeError\":\"{}\",\"canonicalizeOk\":{},\"canonicalizeError\":\"{}\",\"createFileReadAttributesOk\":{},\"createFileError\":{},\"finalDosOk\":{},\"finalDosError\":{},\"finalNtOk\":{},\"finalNtError\":{},\"finalGuidOk\":{},\"finalGuidError\":{}}}",
        current_ok, current_error, canonical_ok, canonical_error, opened, create_error, final_dos, final_dos_error, final_nt, final_nt_error, final_guid, final_guid_error).expect("write result");
}
'@
    $sourcePath = Join-Path $runtime 'current-exe-probe.rs'
    $exe = Join-Path $app 'cc-switch.exe'
    $resultPath = Join-Path $stick 'result.json'
    [IO.File]::WriteAllText($sourcePath,$source,(New-Object Text.UTF8Encoding($false)))
    $rustc = (Get-Command rustc.exe -ErrorAction Stop).Source
    $build = Start-Process -FilePath $rustc -ArgumentList @('--edition=2021',$sourcePath,'-o',$exe) -Wait -PassThru -WindowStyle Hidden
    if ($build.ExitCode -ne 0 -or -not [IO.File]::Exists($exe)) { throw 'Rust current-exe synthetic probe did not build.' }

    $fixturePath = Join-Path $root 'fixture.json'
    $fixture = [ordered]@{
        Root=$root; Exe=$exe; StickRoot=$stick; RuntimeRoot=$runtime
        Environment=[ordered]@{HOME=$stick;USERPROFILE=$stick;APPDATA=$stick;LOCALAPPDATA=$stick;TEMP=$runtime;TMP=$runtime}
        Arguments=@($resultPath)
    }
    [IO.File]::WriteAllText($fixturePath,(ConvertTo-Json $fixture -Depth 5),(New-Object Text.UTF8Encoding($false)))
    $validated = Read-AppContainerFixture -Path $fixturePath
    $state = Start-AppContainerProbeProcess -Fixture $validated -NetworkMode InternetClient
    $wait = Wait-AppContainerProbeProcess -State $state -TimeoutSeconds 20
    if (-not $wait.Completed -or $wait.ExitCode -ne 0 -or -not [IO.File]::Exists($resultPath)) { throw 'AppContainer current-exe probe failed or timed out.' }
    $result = [IO.File]::ReadAllText($resultPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    $sidVerified=[AiStickAppContainerNative]::VerifyAppContainerToken([int]$state.ProcessId,[string]$state.AppContainerSid,$true)
    if (-not $sidVerified) { throw 'Synthetic process did not retain the expected AppContainer token and InternetClient capability.' }
    $exeAcl=Get-Acl -LiteralPath $exe
    $exeFullControl=@($exeAcl.Access|Where-Object {$_.IdentityReference.Value -eq [string]$state.AppContainerSid -and $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl}).Count -gt 0
    $tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $tempAcl=Get-Acl -LiteralPath $tempParent
    $tempSidRulePresent=@($tempAcl.Access|Where-Object {$_.IdentityReference.Value -eq [string]$state.AppContainerSid}).Count -gt 0
    $report=[ordered]@{CurrentExeResolved=[bool]$result.currentExeOk;CurrentExeError=[string]$result.currentExeError;CanonicalizeSucceeded=[bool]$result.canonicalizeOk;CanonicalizeError=[string]$result.canonicalizeError;CreateFileReadAttributesSucceeded=[bool]$result.createFileReadAttributesOk;CreateFileError=[int]$result.createFileError;FinalPathDosSucceeded=[bool]$result.finalDosOk;FinalPathDosError=[int]$result.finalDosError;FinalPathNtSucceeded=[bool]$result.finalNtOk;FinalPathNtError=[int]$result.finalNtError;FinalPathGuidSucceeded=[bool]$result.finalGuidOk;FinalPathGuidError=[int]$result.finalGuidError;ExecutableHasAppContainerFullControl=$exeFullControl;TempParentHasAppContainerAce=$tempSidRulePresent;AppContainerSidVerified=$true;NetworkMode='InternetClient';SecretPayload='None'}
    $reportPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\cc-tauri-current-exe-appcontainer-latest.json'
    [IO.File]::WriteAllText($reportPath,($report|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($true)))
    Write-Output ([pscustomobject]$report)
    Complete-AppContainerProbeProcess -State $state
    $state=$null
    $safeToRemove=$true
} finally {
    if ($state) { try { Complete-AppContainerProbeProcess -State $state; $state=$null; $safeToRemove=$true } catch { Write-Warning 'Synthetic AppContainer cleanup needs inspection; preserving its owned fixture.' } }
    if ($root -and $safeToRemove -and [IO.Directory]::Exists($root)) {
        $full=[IO.Path]::GetFullPath($root).TrimEnd('\','/')
        $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        $leaf=Split-Path -Leaf $full
        $parsed=[guid]::Empty
        if ([string]::Equals((Split-Path -Parent $full).TrimEnd('\','/'),$temp,[StringComparison]::OrdinalIgnoreCase) -and $leaf.StartsWith('aistick-ac-probe-',[StringComparison]::Ordinal) -and [guid]::TryParseExact($leaf.Substring('aistick-ac-probe-'.Length),'N',[ref]$parsed)) {
            $marker=Join-Path $full '.aistick-ac-probe'
            if ([IO.File]::Exists($marker) -and -not ((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { Remove-Item -LiteralPath $full -Recurse -Force }
        }
    }
}
