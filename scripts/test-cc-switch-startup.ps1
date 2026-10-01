[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aistick-startup-test-' + [guid]::NewGuid().ToString('N'))))
[void][IO.Directory]::CreateDirectory($root)
$locator = Join-Path $root 'locator.json'
$script:PipeExists = $false
$script:Unlocked = $false
$script:ProviderName = 'Synthetic provider'
$script:StartCount = 0
$script:StaleThrows = $false
$script:Answers = @()

try {
    . (Join-Path $PSScriptRoot 'cc-switch-startup.ps1') -StickRoot $root

    function Get-CcSecurePipeName { param([string]$Root) return 'test-pipe' }
    function Get-CcSecureLocatorPath { param([string]$PipeName) return $script:locator }
    function Test-CcSecureSessionPipeAvailable { param([string]$StickRoot,[string]$PipeName) return [bool]$script:PipeExists }
    function Get-CcSecureSessionStatus { param([string]$StickRoot) return [pscustomobject]@{Unlocked=[bool]$script:Unlocked;ProviderName=$script:ProviderName} }
    function Assert-CcSecureSessionStaleLocator { param([string]$StickRoot,[string]$PipeName,[string]$LocatorPath) if($script:StaleThrows){throw 'synthetic protected stale-locator validation failure'} }
    function Start-CcSwitchStartupManager { param([string]$Root) $script:StartCount++; if($script:StartCount -eq 1){$script:Unlocked=$true;$script:PipeExists=$true;[IO.File]::WriteAllText($script:locator,'synthetic locator')} }
    function Read-Host { param([string]$Prompt) if($script:Answers.Count -eq 0){return 'Q'}; $answer=$script:Answers[0];$script:Answers=@($script:Answers | Select-Object -Skip 1);return $answer }

    function Reset-Fixture {
        $script:PipeExists=$false;$script:Unlocked=$false;$script:ProviderName='Synthetic provider';$script:StartCount=0;$script:StaleThrows=$false;$script:Answers=@()
        if(Test-Path -LiteralPath $script:locator){Remove-Item -LiteralPath $script:locator -Force}
    }
    function Assert-Fixture([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message};Write-Output ('PASS: '+$Message) }

    # Missing locator + missing pipe safely starts one manager and only proceeds
    # after an authenticated Unlocked status response.
    Reset-Fixture
    $script:Answers=@('')
    $result=Ensure-CcSwitchStartupSession -Root $root -Interactive $true
    Assert-Fixture ($result.Unlocked -and $script:StartCount -eq 1) 'empty state bootstraps and waits for authenticated unlock'

    # A live pipe without its protected locator is ambiguous and must fail closed.
    Reset-Fixture
    $script:PipeExists=$true
    $failed=$false;try{$null=Ensure-CcSwitchStartupSession -Root $root -Interactive $true}catch{$failed=$true}
    Assert-Fixture ($failed -and $script:StartCount -eq 0) 'missing locator with live pipe is rejected without launching a host'

    # A stale locator must pass the dedicated integrity check before relaunch.
    Reset-Fixture
    [IO.File]::WriteAllText($locator,'{}')
    $script:StaleThrows=$true
    $failed=$false;try{$null=Ensure-CcSwitchStartupSession -Root $root -Interactive $true}catch{$failed=$_.Exception.Message -match 'synthetic protected stale-locator validation failure'}
    Assert-Fixture ($failed -and $script:StartCount -eq 0) 'stale-locator validation errors escape without launching a host'

    # An already authenticated, unlocked session is reused without opening a
    # second manager. No GUI request is made by this bootstrap helper.
    Reset-Fixture
    [IO.File]::WriteAllText($locator,'{}')
    $script:PipeExists=$true;$script:Unlocked=$true
    $null=Ensure-CcSwitchStartupSession -Root $root -Interactive $true
    Assert-Fixture ($script:StartCount -eq 0) 'existing unlocked session is reused without a second manager'

    Reset-Fixture
    $script:Answers=@('Q')
    $failed=$false;try{$null=Ensure-CcSwitchStartupSession -Root $root -Interactive $true}catch{$failed=$_.Exception.Message -match '用户取消'}
    Assert-Fixture ($failed -and $script:StartCount -eq 1 -and $script:PipeExists) 'user cancellation stops this launch and leaves the password window running'

    Reset-Fixture
    $script:Answers=@('')
    function Start-CcSwitchStartupManager { param([string]$Root) $script:StartCount++ }
    $failed=$false;try{$null=Ensure-CcSwitchStartupSession -Root $root -Interactive $true}catch{$failed=$true}
    Assert-Fixture ($failed -and $script:StartCount -eq 1) 'closed or failed host ends without automatically opening a second host'

    Reset-Fixture
    $script:ProviderName=$null;$script:Unlocked=$true;$script:PipeExists=$true
    [IO.File]::WriteAllText($locator,'{}')
    $failed=$false;try{$null=Ensure-CcSwitchStartupSession -Root $root -Interactive $true}catch{$failed=$_.Exception.Message -match '还没有可用的 Claude 供应商'}
    Assert-Fixture ($failed -and $script:StartCount -eq 0) 'unconfigured provider gets a friendly setup error without fallback'

    Reset-Fixture
    $script:PipeExists=$true
    [IO.File]::WriteAllText($locator,'{}')
    function Get-CcSecureSessionStatus { param([string]$StickRoot) throw 'synthetic protected ACL/PID authentication failure' }
    $failed=$false;try{$null=Ensure-CcSwitchStartupSession -Root $root -Interactive $true}catch{$failed=$_.Exception.Message -match 'synthetic protected ACL/PID authentication failure'}
    Assert-Fixture ($failed -and $script:StartCount -eq 0) 'authenticated status errors escape without opening another host'

    Reset-Fixture
    $failed=$false;try{$null=Ensure-CcSwitchStartupSession -Root $root -Interactive $false}catch{$failed=$_.Exception.Message -match 'AI设置'}
    Assert-Fixture ($failed -and $script:StartCount -eq 0 -and $script:Answers.Count -eq 0) 'noninteractive mode fails with instructions without prompting or launching'

    $launchPath=Join-Path $PSScriptRoot 'launch.ps1'
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($launchPath,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw 'Could not parse launcher guard AST.'}
    $guard=$ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match '\$unifiedMode\s+-and\s+\$interactive'},$true)|Select-Object -First 1
    Assert-Fixture ($guard -and $guard.Extent.Text -match 'IsInputRedirected' -and $guard.Extent.Text -match 'Ensure-CcSwitchStartupSession') 'interactive authenticated guard excludes redirected runs and precedes launch-bundle resolution'
} finally {
    foreach($name in @('Get-CcSecurePipeName','Get-CcSecureLocatorPath','Test-CcSecureSessionPipeAvailable','Get-CcSecureSessionStatus','Assert-CcSecureSessionStaleLocator','Start-CcSwitchStartupManager','Read-Host')) { Remove-Item -LiteralPath ('Function:\'+ $name) -ErrorAction SilentlyContinue }
    if(Test-Path -LiteralPath $root){
        $resolved=[IO.Path]::GetFullPath($root).TrimEnd('\','/')
        $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        if((Split-Path -Parent $resolved).TrimEnd('\','/') -cne $tempRoot -or (Split-Path -Leaf $resolved) -notmatch '^aistick-startup-test-[0-9a-f]{32}$'){throw 'Refusing to clean an unexpected startup-test fixture path.'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
