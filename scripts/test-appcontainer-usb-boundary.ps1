[CmdletBinding()]param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sentinelRoot=Join-Path (Join-Path $project 'docs') ('cc-usb-boundary-'+[guid]::NewGuid().ToString('N'))
$root=$null;$state=$null;$mutex=$null
try {
    [void][IO.Directory]::CreateDirectory($sentinelRoot)
    $sentinel=Join-Path $sentinelRoot 'synthetic-sentinel.txt'
    [IO.File]::WriteAllText($sentinel,'Synthetic USB boundary sentinel')
    $before=(Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash
    $root=New-AppContainerProbeFixtureRoot
    foreach($dir in @('app','stick','runtime')){[void][IO.Directory]::CreateDirectory((Join-Path $root $dir))}
    [IO.File]::WriteAllText((Join-Path $root '.aistick-ac-probe'),'aistick appcontainer workspace v1')
    # Use the same reviewed worker source as the standard NTFS sentinel test.
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-appcontainer-boundary.ps1'),[ref]$tokens,[ref]$errors)
    $assignment=$ast.Find({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -eq 'workerSource'},$true)
    if(-not $assignment){throw 'Reviewed worker source was not found.'}
    $literal=$assignment.Right.Find({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst]},$true)
    if(-not $literal){throw 'Worker source must be a literal string.'}
    $workerSource=$literal.Value
    $exe=Join-Path $root 'app\cc-switch.exe'
    Add-Type -TypeDefinition $workerSource -OutputType ConsoleApplication -OutputAssembly $exe -ErrorAction Stop
    $mutexName='AiStick.UsbBoundary.'+[guid]::NewGuid().ToString('N')
    $mutex=New-Object Threading.Mutex($true,$mutexName)
    $result=Join-Path $root 'runtime\result.json'
    $fixturePath=Join-Path $root 'fixture.json'
    $stick=Join-Path $root 'stick'
    $environment=[ordered]@{HOME=$stick;USERPROFILE=$stick;APPDATA=$stick;LOCALAPPDATA=$stick;CC_SWITCH_TEST_HOME=$stick;TEMP=$stick;TMP=$stick;WEBVIEW2_USER_DATA_FOLDER=$stick}
    $fixture=[ordered]@{Root=$root;Exe=$exe;StickRoot=$stick;RuntimeRoot=(Join-Path $root 'runtime');Environment=$environment;Arguments=@((Join-Path $root 'stick\managed-write.txt'),$sentinel,$mutexName,$result)}
    [IO.File]::WriteAllText($fixturePath,($fixture|ConvertTo-Json -Depth 6))
    $state=Start-AppContainerProbeProcess -Fixture (Read-AppContainerFixture -Path $fixturePath)
    $wait=Wait-AppContainerProbeProcess -State $state -TimeoutSeconds 20
    if(-not $wait.Completed){throw 'USB boundary worker timed out.'}
    $observed=[IO.File]::ReadAllText($result)|ConvertFrom-Json
    if(-not $observed.tokenIsAppContainer -or -not $observed.managedWriteSucceeded -or -not $observed.hostWriteDenied -or -not $observed.mutexCreatedNew -or $wait.ExitCode -ne 0){throw 'USB sentinel boundary was not enforced.'}
    if((Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash -ne $before){throw 'USB sentinel changed.'}
    Write-Host 'PASS USB-volume sentinel write denied, hash unchanged, managed write and mutex isolation verified'
} finally {
    if($state){Complete-AppContainerProbeProcess -State $state}
    if($mutex){$mutex.Dispose()}
    if($root){
        $full=[IO.Path]::GetFullPath($root).TrimEnd('\')
        if((Split-Path -Parent $full) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or (Split-Path -Leaf $full) -notmatch '^aistick-ac-probe-[0-9a-f]{32}$'){throw 'Unexpected worker cleanup root.'}
        if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
    }
    $full=[IO.Path]::GetFullPath($sentinelRoot)
    if((Split-Path -Parent $full) -ne (Join-Path $project 'docs') -or (Split-Path -Leaf $full) -notmatch '^cc-usb-boundary-[0-9a-f]{32}$'){throw 'Unexpected sentinel cleanup root.'}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
