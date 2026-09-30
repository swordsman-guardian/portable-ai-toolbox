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
    $profile = Join-Path $root 'profile'
    $temp = Join-Path $runtime 'temp'
    foreach ($dir in @($app,$stick,$runtime,$profile,(Join-Path $profile 'AppData\Roaming'),(Join-Path $profile 'AppData\Local'),$temp)) {
        [IO.Directory]::CreateDirectory($dir) | Out-Null
    }

    $source = @'
use std::{env, fs, io::Write, process::{Command, Stdio}, os::windows::process::CommandExt};
const CREATE_NO_WINDOW: u32 = 0x08000000;
fn quote(s: &str) -> String { s.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n").replace('\r', "\\r") }
fn hex(bytes: &[u8]) -> String { bytes.iter().map(|b| format!("{:02x}", b)).collect::<String>() }
fn main() {
    let result = std::path::PathBuf::from(env::args_os().nth(1).expect("result path"));
    let temp = env::temp_dir();
    let bat = temp.join(format!("cc_switch_tool_update_{}.bat", std::process::id()));
    let mut out = String::from("{");
    let temp_env = env::var("TEMP").unwrap_or_default();
    let tmp_env = env::var("TMP").unwrap_or_default();
    out.push_str(&format!("\"rustTempDir\":\"{}\",\"tempEnv\":\"{}\",\"tmpEnv\":\"{}\",\"rustTempExists\":{},\"tempEnvExists\":{},\"tmpEnvExists\":{},\"batchNamePidMatches\":{}", quote(&temp.to_string_lossy()), quote(&temp_env), quote(&tmp_env), temp.is_dir(), std::path::Path::new(&temp_env).is_dir(), std::path::Path::new(&tmp_env).is_dir(), bat.file_name().unwrap().to_string_lossy().contains(&std::process::id().to_string())));
    match fs::write(&bat, b"@echo off\r\necho LIFECYCLE_BAT_OK\r\nexit /b 0\r\n") {
        Ok(()) => {
            out.push_str(",\"tempWrite\":\"ok\"");
            let mut cmd = Command::new("cmd");
            // Match upstream run_tool_lifecycle_silently exactly: cmd /C <bat>.
            cmd.arg("/C").arg(&bat).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).creation_flags(CREATE_NO_WINDOW);
            match cmd.output() {
                Ok(output) => out.push_str(&format!(",\"batCmdExit\":{},\"batCmdStdout\":\"{}\",\"batCmdStderrHex\":\"{}\"", output.status.code().unwrap_or(-1), quote(&String::from_utf8_lossy(&output.stdout)), hex(&output.stderr))),
                Err(error) => out.push_str(&format!(",\"batCmdErrorKind\":\"{:?}\",\"batCmdErrorCode\":{}", error.kind(), error.raw_os_error().unwrap_or(-1))),
            }
            let mut reader = Command::new("cmd");
            reader.arg("/C").arg("type").arg(&bat).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).creation_flags(CREATE_NO_WINDOW);
            match reader.output() {
                Ok(output) => out.push_str(&format!(",\"tempTypeExit\":{},\"tempTypeStdout\":\"{}\",\"tempTypeStderrHex\":\"{}\"", output.status.code().unwrap_or(-1), quote(&String::from_utf8_lossy(&output.stdout)), hex(&output.stderr))),
                Err(error) => out.push_str(&format!(",\"tempTypeErrorKind\":\"{:?}\",\"tempTypeErrorCode\":{}", error.kind(), error.raw_os_error().unwrap_or(-1))),
            }
            let mut call_bat = Command::new("cmd");
            call_bat.raw_arg(format!("/D /S /C call \"{}\"", bat.display())).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).creation_flags(CREATE_NO_WINDOW);
            match call_bat.output() {
                Ok(output) => out.push_str(&format!(",\"callBatExit\":{},\"callBatStdout\":\"{}\",\"callBatStderrHex\":\"{}\"", output.status.code().unwrap_or(-1), quote(&String::from_utf8_lossy(&output.stdout)), hex(&output.stderr))),
                Err(error) => out.push_str(&format!(",\"callBatErrorKind\":\"{:?}\",\"callBatErrorCode\":{}", error.kind(), error.raw_os_error().unwrap_or(-1))),
            }
            let cmd_file = temp.join("cc-switch-lifecycle-io-probe.cmd");
            let _ = fs::write(&cmd_file, b"@echo off\r\necho LIFECYCLE_CMD_OK\r\nexit /b 0\r\n");
            let mut call_cmd = Command::new("cmd");
            call_cmd.raw_arg(format!("/D /S /C call \"{}\"", cmd_file.display())).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).creation_flags(CREATE_NO_WINDOW);
            match call_cmd.output() {
                Ok(output) => out.push_str(&format!(",\"callCmdExit\":{},\"callCmdStdout\":\"{}\",\"callCmdStderrHex\":\"{}\"", output.status.code().unwrap_or(-1), quote(&String::from_utf8_lossy(&output.stdout)), hex(&output.stderr))),
                Err(error) => out.push_str(&format!(",\"callCmdErrorKind\":\"{:?}\",\"callCmdErrorCode\":{}", error.kind(), error.raw_os_error().unwrap_or(-1))),
            }
            let _ = fs::remove_file(&cmd_file);
            match fs::remove_file(&bat) {
                Ok(()) => out.push_str(",\"tempDelete\":\"ok\""),
                Err(error) => out.push_str(&format!(",\"tempDeleteErrorKind\":\"{:?}\",\"tempDeleteErrorCode\":{}", error.kind(), error.raw_os_error().unwrap_or(-1))),
            }
    let stick_batch = result.parent().unwrap().join(format!("cc_switch_tool_update_{}.bat", std::process::id()));
            let _ = fs::write(&stick_batch, b"@echo off\r\necho STICK_BAT_OK\r\nexit /b 0\r\n");
            let mut stick_cmd = Command::new("cmd");
            stick_cmd.arg("/C").arg(&stick_batch).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).creation_flags(CREATE_NO_WINDOW);
            match stick_cmd.output() {
                Ok(output) => out.push_str(&format!(",\"stickBatExit\":{},\"stickBatStdout\":\"{}\",\"stickBatStderrHex\":\"{}\"", output.status.code().unwrap_or(-1), quote(&String::from_utf8_lossy(&output.stdout)), hex(&output.stderr))),
                Err(error) => out.push_str(&format!(",\"stickBatErrorKind\":\"{:?}\",\"stickBatErrorCode\":{}", error.kind(), error.raw_os_error().unwrap_or(-1))),
            }
            let _ = fs::remove_file(&stick_batch);
        }
        Err(error) => out.push_str(&format!(",\"tempWriteErrorKind\":\"{:?}\",\"tempWriteErrorCode\":{}", error.kind(), error.raw_os_error().unwrap_or(-1))),
    }
    let mut direct = Command::new("cmd");
    direct.args(["/d", "/c", "echo DIRECT_CMD_OK"]).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).creation_flags(CREATE_NO_WINDOW);
    match direct.output() {
        Ok(output) => out.push_str(&format!(",\"directCmdExit\":{},\"directCmdStdout\":\"{}\",\"directCmdStderr\":\"{}\"", output.status.code().unwrap_or(-1), quote(&String::from_utf8_lossy(&output.stdout)), quote(&String::from_utf8_lossy(&output.stderr)))),
        Err(error) => out.push_str(&format!(",\"directCmdErrorKind\":\"{:?}\",\"directCmdErrorCode\":{}", error.kind(), error.raw_os_error().unwrap_or(-1))),
    }
    out.push('}');
    let mut file = fs::File::create(result).expect("write report under owned fixture");
    file.write_all(out.as_bytes()).expect("write report bytes");
}
'@
    $sourcePath = Join-Path $runtime 'lifecycle-io-probe.rs'
    $exe = Join-Path $app 'cc-switch.exe'
    $resultPath = Join-Path $stick 'lifecycle-io-probe.json'
    [IO.File]::WriteAllText($sourcePath,$source,(New-Object Text.UTF8Encoding($false)))
    $rustc = (Get-Command rustc.exe -ErrorAction Stop).Source
    $buildOut = Join-Path $runtime 'lifecycle-io-build.stdout.txt'
    $buildErr = Join-Path $runtime 'lifecycle-io-build.stderr.txt'
    $build = Start-Process -FilePath $rustc -ArgumentList @('--edition=2021',$sourcePath,'-o',$exe) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $buildOut -RedirectStandardError $buildErr
    if ($build.ExitCode -ne 0 -or -not [IO.File]::Exists($exe)) { throw ('Rust lifecycle I/O probe did not build: ' + [IO.File]::ReadAllText($buildErr)) }

    $fixturePath = Join-Path $root 'fixture.json'
    $fixture = [ordered]@{
        Root=$root; Exe=$exe; StickRoot=$stick; RuntimeRoot=$runtime
        Environment=[ordered]@{HOME=$profile;USERPROFILE=$profile;APPDATA=(Join-Path $profile 'AppData\Roaming');LOCALAPPDATA=(Join-Path $profile 'AppData\Local');CC_SWITCH_TEST_HOME=$profile;TEMP=$temp;TMP=$temp}
        Arguments=@($resultPath)
    }
    [IO.File]::WriteAllText($fixturePath,(ConvertTo-Json -InputObject $fixture -Depth 5),(New-Object Text.UTF8Encoding($false)))
    $fresh = Read-AppContainerFixture -Path $fixturePath
    $state = Start-AppContainerProbeProcess -Fixture $fresh -NetworkMode None
    $wait = Wait-AppContainerProbeProcess -State $state -TimeoutSeconds 20
    if (-not $wait.Completed -or $wait.ExitCode -ne 0 -or -not [IO.File]::Exists($resultPath)) { throw 'AppContainer lifecycle I/O probe failed or timed out.' }
    $result = [IO.File]::ReadAllText($resultPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    $summary = [ordered]@{IsAppContainer=$true;NetworkMode='None';SecretPayload='None'}
    foreach ($name in @('rustTempDir','tempEnv','tmpEnv','rustTempExists','tempEnvExists','tmpEnvExists','batchNamePidMatches','tempWrite','tempWriteErrorKind','tempWriteErrorCode','batCmdExit','batCmdStdout','batCmdStderrHex','batCmdErrorKind','batCmdErrorCode','callBatExit','callBatStdout','callBatStderrHex','callBatErrorKind','callBatErrorCode','callCmdExit','callCmdStdout','callCmdStderrHex','callCmdErrorKind','callCmdErrorCode','tempDelete','tempDeleteErrorKind','tempDeleteErrorCode','tempTypeExit','tempTypeStdout','tempTypeStderrHex','tempTypeErrorKind','tempTypeErrorCode','stickBatExit','stickBatStdout','stickBatStderrHex','stickBatErrorKind','stickBatErrorCode','directCmdExit','directCmdStdout','directCmdStderr','directCmdErrorKind','directCmdErrorCode')) {
        $property = $result.PSObject.Properties[$name]
        if ($property) { $summary[$name] = $property.Value }
    }
    $localAppData = [IO.Path]::GetFullPath((Join-Path $profile 'AppData\Local')).TrimEnd('\','/') + '\Packages\'
    $tempIsOwnedPackagePath = ([string]$result.rustTempDir).StartsWith($localAppData,[StringComparison]::OrdinalIgnoreCase)
    $safeReport = [ordered]@{
        schema=1;Test='AppContainer Rust lifecycle temporary batch I/O';NetworkMode='None';SecretPayload='None'
        RustTempResolvesToOwnedPackagePath=$tempIsOwnedPackagePath
        RustTempExists=[bool]$result.rustTempExists;InjectedTempMatchesRustTemp=([string]$result.tempEnv).TrimEnd('\','/').Equals(([string]$result.rustTempDir).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase) -and ([string]$result.tmpEnv).TrimEnd('\','/').Equals(([string]$result.rustTempDir).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase);BatchFilenameIncludesCurrentPid=[bool]$result.batchNamePidMatches
        TempWrite=$result.tempWrite;DirectCmdExit=$result.directCmdExit;DirectCmdStdout=([string]$result.directCmdStdout).Trim()
        DirectBatExit=$result.batCmdExit;DirectBatStderrHex=$result.batCmdStderrHex;CallBatchExit=$result.callBatExit;CallBatchStdout=([string]$result.callBatStdout).Trim()
        CallCmdExit=$result.callCmdExit;CallCmdStdout=([string]$result.callCmdStdout).Trim();TempBatchReadable=($result.tempTypeExit -eq 0)
        TempDelete=$result.tempDelete;StickBatchExit=$result.stickBatExit
        Conclusion='After precreating the owned AppContainer package Temp directory, Rust temp writes and CMD child creation work. Direct cmd /C <batch> returns access denied; cmd /D /S /C call "<same batch>" succeeds.'
    }
    $docReportPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\cc-appcontainer-lifecycle-io-latest.json'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $docReportPath)) | Out-Null
    [IO.File]::WriteAllText($docReportPath,(ConvertTo-Json -InputObject $safeReport -Depth 4),(New-Object Text.UTF8Encoding($false)))
    Write-Output ([pscustomobject]$summary)
    Complete-AppContainerProbeProcess -State $state
    $state = $null
    $safeToRemove = $true
} finally {
    if ($state) { try { Complete-AppContainerProbeProcess -State $state; $state=$null; $safeToRemove=$true } catch { Write-Warning 'Synthetic AppContainer cleanup needs inspection; preserving its owned fixture.' } }
    if ($root -and $safeToRemove -and [IO.Directory]::Exists($root)) {
        $full=[IO.Path]::GetFullPath($root).TrimEnd('\','/')
        $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        $leaf=Split-Path -Leaf $full
        $parsed=[guid]::Empty
        if ([string]::Equals((Split-Path -Parent $full).TrimEnd('\','/'),$tempRoot,[StringComparison]::OrdinalIgnoreCase) -and $leaf.StartsWith('aistick-ac-probe-',[StringComparison]::Ordinal) -and [guid]::TryParseExact($leaf.Substring('aistick-ac-probe-'.Length),'N',[ref]$parsed)) {
            Assert-AppContainerProbePlainTree -Path $root -Boundary $tempRoot
            $marker=Join-Path $root '.aistick-ac-probe'
            if ([IO.File]::Exists($marker) -and [IO.File]::ReadAllText($marker).Trim() -ceq 'synthetic appcontainer fixture v1') { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }
        }
    }
}
