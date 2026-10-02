[CmdletBinding()]param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 5){throw 'Run this test with Windows PowerShell 5.1.'}

$wrapperSource=Join-Path $PSScriptRoot 'cc-switch-secure-manager-window.ps1'
$parseTokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($wrapperSource,[ref]$parseTokens,[ref]$parseErrors)
if($parseErrors.Count){throw ('Secure manager window wrapper did not parse: '+($parseErrors -join '; '))}
$parameters=$ast.ParamBlock.Parameters.Name.VariablePath.UserPath
if(($parameters -join ',') -cne 'StickRoot,NetworkMode,ImportToolboxBeforeLaunch') { throw 'Wrapper exposed an unexpected launch parameter.' }
$isolatedAst=$null;$isolatedTokens=$null;$isolatedParseErrors=$null
$isolatedAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'cc-switch-isolated.ps1'),[ref]$isolatedTokens,[ref]$isolatedParseErrors)
if($isolatedParseErrors.Count){throw 'Isolated launcher did not parse.'}
$quoteFunction=$isolatedAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Quote-SecureManagerArgument'},$true)
if(-not $quoteFunction){throw 'Could not find the production argument quoting helper.'}
Invoke-Expression $quoteFunction.Extent.Text

$testRoot=Join-Path ([IO.Path]::GetTempPath()) ("cc secure manager's test-"+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot)|Out-Null
try{
    $wrapper=Join-Path $testRoot 'cc-switch-secure-manager-window.ps1'
    $manager=Join-Path $testRoot 'cc-switch-secure-session.ps1'
    $inputPath=Join-Path $testRoot 'input.txt'
    [IO.File]::WriteAllText($wrapper,[IO.File]::ReadAllText($wrapperSource),(New-Object Text.UTF8Encoding($true)))
    [IO.File]::WriteAllText($inputPath,"`r`n",(New-Object Text.UTF8Encoding($false)))
    $powerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $out=Join-Path $testRoot 'failure.out';$err=Join-Path $testRoot 'failure.err'
    [IO.File]::WriteAllText($manager,"param([string]`$StickRoot,[string]`$NetworkMode,[switch]`$ImportToolboxBeforeLaunch) throw 'synthetic startup failure'",(New-Object Text.UTF8Encoding($false)))
    $launchArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapper,'-StickRoot',$testRoot,'-NetworkMode','None')
    $quotedArgs=@($launchArguments | ForEach-Object { Quote-SecureManagerArgument ([string]$_) })
    $proc=Start-Process -FilePath $powerShell -ArgumentList $quotedArgs -PassThru -Wait -RedirectStandardInput $inputPath -RedirectStandardOutput $out -RedirectStandardError $err
    $failureText=[IO.File]::ReadAllText($out)+[IO.File]::ReadAllText($err)
    if($proc.ExitCode -ne 1 -or $failureText -notmatch 'synthetic startup failure' -or $failureText -match 'At .* line:|CategoryInfo|FullyQualifiedErrorId') { throw 'Failure wrapper did not show only the exception message and exit with failure.' }

    $expectedRoot="'"+$testRoot.Replace("'","''")+"'"
    [IO.File]::WriteAllText($manager,"param([string]`$StickRoot,[string]`$NetworkMode,[switch]`$ImportToolboxBeforeLaunch) if (`$StickRoot -ne $expectedRoot) { throw 'StickRoot was not forwarded.' }; if (`$NetworkMode -ne 'InternetClient' -or -not `$ImportToolboxBeforeLaunch) { throw 'Manager options were not forwarded.' }",(New-Object Text.UTF8Encoding($false)))
    $launchArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapper,'-StickRoot',$testRoot,'-NetworkMode','InternetClient','-ImportToolboxBeforeLaunch')
    $quotedArgs=@($launchArguments | ForEach-Object { Quote-SecureManagerArgument ([string]$_) })
    $proc=Start-Process -FilePath $powerShell -ArgumentList $quotedArgs -PassThru -Wait -RedirectStandardInput $inputPath -RedirectStandardOutput $out -RedirectStandardError $err
    if($proc.ExitCode -ne 0){throw 'Successful manager call did not exit normally.'}
    Write-Host 'Secure manager wrapper -File execution checks passed.' -ForegroundColor Green
}finally{
    if([IO.Directory]::Exists($testRoot)){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
