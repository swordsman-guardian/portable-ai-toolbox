[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'cc-switch-legacy-plaintext-cleanup.ps1')
function Assert-Test([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Write-Json([string]$Path,$Value){$Value|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $Path -Encoding UTF8}
$script:Unified=$true;$script:Unlocked=$true;$script:Revision='r1';$script:Bundle=$null
function Get-CcSwitchUnifiedMode([string]$StickRoot){$script:Unified}
function Get-CcSecureSessionStatus([string]$StickRoot){[pscustomobject]@{Unlocked=$script:Unlocked;LastSaveStatus='Saved'}}
function Get-CcEncryptedStoreStatus([string]$StickRoot){[pscustomobject]@{CurrentRevision=$script:Revision}}
function Get-CcSecureSessionClaudeLaunchBundle([string]$StickRoot){return [pscustomobject]@{Revision=$script:Bundle.Revision;Provider=[pscustomobject]@{Name=$script:Bundle.Provider.Name;BaseUrl=$script:Bundle.Provider.BaseUrl;AuthEnvironmentName=$script:Bundle.Provider.AuthEnvironmentName;Models=$script:Bundle.Provider.Models;Secret=(ConvertTo-SecureString 'synthetic-secret-001' -AsPlainText -Force)};LaunchFiles=$script:Bundle.LaunchFiles}}
function Initialize-Fixture([string]$Root,[bool]$ExtraProvider=$false){
 $config=Join-Path $Root 'config';$claude=Join-Path $config 'claude';$harness=Join-Path $Root 'harness';$docs=Join-Path $Root 'docs'
 New-Item -ItemType Directory -Path $claude,$harness,$docs,(Join-Path $config 'secure-store'),(Join-Path $Root 'history') -Force|Out-Null
 $secret='synthetic-secret-001';$keyName='CLAUDE_TEST_KEY';$authName='ANTHROPIC_AUTH_TOKEN';$base='https://example.invalid/v1';$model='synthetic-model'
 Set-Content -LiteralPath (Join-Path $config 'keys.env') -Value ($keyName+'='+$secret) -Encoding UTF8
 $provider=[pscustomobject]@{id='p1';name='Synthetic';enabled=$true;baseUrl=$base;apikeyEnv=$keyName;models=[pscustomobject]@{ANTHROPIC_MODEL=$model};extraEnv=[pscustomobject]@{SYNTHETIC_FLAG='on'};verified='yes';notes='retained'}
 $providers=@($provider);if($ExtraProvider){$providers+=([pscustomobject]@{id='disabled';name='disabled';enabled=$false;baseUrl='https://disabled.invalid';apikeyEnv='EXTRA';models=[pscustomobject]@{};extraEnv=[pscustomobject]@{}})}
 Write-Json (Join-Path $harness 'providers.json') ([pscustomobject]@{default='p1';providers=$providers})
 Write-Json (Join-Path $Root 'config\settings.json') ([pscustomobject]@{provider='p1'})
 Write-Json (Join-Path $harness 'registry.json') ([pscustomobject]@{harnesses=@([pscustomobject]@{id='claude';enabled=$true;providerEnv=[pscustomobject]@{baseUrl='ANTHROPIC_BASE_URL';apiKey=$authName}})})
 $old=[pscustomobject]@{env=[pscustomobject]@{ANTHROPIC_BASE_URL=$base;$authName=$secret;ANTHROPIC_MODEL=$model;SYNTHETIC_FLAG='on';KEEP_ME='keep'};permissions=[pscustomobject]@{allow=@('Read')};enableAllProjectMcpServers=$true}
 Write-Json (Join-Path $claude 'settings.json') $old;Write-Json (Join-Path $claude 'settings.json.bak') $old
 Set-Content -LiteralPath (Join-Path $config 'secure-store\current') -Value 'preserve' -Encoding ASCII
 Set-Content -LiteralPath (Join-Path $Root 'history\history.jsonl') -Value 'preserve' -Encoding ASCII
 $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($old|ConvertTo-Json -Depth 20)))
 $script:Bundle=[pscustomobject]@{Revision=$script:Revision;Provider=[pscustomobject]@{Name='Synthetic';BaseUrl=$base;AuthEnvironmentName=$authName;Models=@{ANTHROPIC_MODEL=$model};Secret=$null};LaunchFiles=@([pscustomobject]@{Path='settings.json';ContentBase64=$encoded})}
 return [pscustomobject]@{Config=$config;Claude=$claude;Harness=$harness}
}
$root=Join-Path $env:TEMP ('cc-cleanup-test-'+[guid]::NewGuid().ToString('N'))
try{
 if(-not [IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath($env:TEMP),[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected synthetic test path.'}
 $f=Initialize-Fixture $root -ExtraProvider $true
 $failed=$false;try{Get-CcSwitchLegacyPlaintextCleanupPlan -StickRoot $root|Out-Null}catch{$failed=$true};Assert-Test $failed 'Cleanup accepted an additional disabled provider.'
 Remove-Item -LiteralPath (Join-Path $f.Harness 'providers.json') -Force
 $provider=[pscustomobject]@{id='p1';name='Synthetic';enabled=$true;baseUrl='https://example.invalid/v1';apikeyEnv='CLAUDE_TEST_KEY';models=[pscustomobject]@{ANTHROPIC_MODEL='synthetic-model'};extraEnv=[pscustomobject]@{SYNTHETIC_FLAG='on'};verified='yes';notes='retained'}
 Write-Json (Join-Path $f.Harness 'providers.json') ([pscustomobject]@{default='p1';providers=@($provider)})
 $script:Unified=$false;$failed=$false;try{Get-CcSwitchLegacyPlaintextCleanupPlan -StickRoot $root|Out-Null}catch{$failed=$true};Assert-Test $failed 'Cleanup accepted unified mode=false.';$script:Unified=$true
 $plan=Get-CcSwitchLegacyPlaintextCleanupPlan -StickRoot $root
 Assert-Test ($plan.Targets.Count -eq 4) 'Expected three exact source files and one byte-identical backup.'
 Assert-Test (-not ($plan|ConvertTo-Json -Depth 10|Select-String -Pattern 'Hash|Secret|synthetic-secret')) 'Public plan leaked sensitive data.'
 $dry=Remove-CcSwitchLegacyPlaintextFiles -Plan $plan -WhatIf
 Assert-Test ($dry.WhatIfOnly -and $dry.RemovedCount -eq 0 -and (Test-Path -LiteralPath (Join-Path $f.Config 'keys.env'))) 'WhatIf did not preserve files or plan.'
 $stale=Get-CcSwitchLegacyPlaintextCleanupPlan -StickRoot $root
 $bytes=[IO.File]::ReadAllBytes((Join-Path $f.Config 'keys.env'));$bytes[$bytes.Length-2]=[byte]([int]$bytes[$bytes.Length-2] -bxor 1);[IO.File]::WriteAllBytes((Join-Path $f.Config 'keys.env'),$bytes)
 $failed=$false;try{Remove-CcSwitchLegacyPlaintextFiles -Plan $stale -Confirm:$false|Out-Null}catch{$failed=$true};Assert-Test $failed 'Cleanup accepted same-length source mutation after planning.'
 Set-Content -LiteralPath (Join-Path $f.Config 'keys.env') -Value 'CLAUDE_TEST_KEY=synthetic-secret-001' -Encoding UTF8
 $plan=Get-CcSwitchLegacyPlaintextCleanupPlan -StickRoot $root
 $result=Remove-CcSwitchLegacyPlaintextFiles -Plan $plan -Confirm:$false
 Assert-Test ($result.RemovedCount -eq 4) 'Expected all approved files to be removed.'
 foreach($path in @((Join-Path $f.Config 'keys.env'),(Join-Path $f.Harness 'providers.json'),(Join-Path $f.Claude 'settings.json'),(Join-Path $f.Claude 'settings.json.bak'))){Assert-Test (-not (Test-Path -LiteralPath $path)) 'Approved file remains.'}
 Assert-Test (Test-Path -LiteralPath (Join-Path $f.Harness 'registry.json')) 'Registry was removed.'
 Assert-Test (Test-Path -LiteralPath (Join-Path $f.Config 'secure-store\current')) 'Encrypted store was removed.'
 Assert-Test (Test-Path -LiteralPath (Join-Path $root 'history\history.jsonl')) 'History was removed.'
 'PASS: synthetic cleanup gates, stale-source refusal, WhatIf, exact deletion'
} finally {
 if(Test-Path -LiteralPath $root){$full=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\';if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing recursive cleanup outside TEMP.'};$item=Get-Item -LiteralPath $full -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint)-ne 0){throw 'Refusing recursive cleanup through reparse point.'};Remove-Item -LiteralPath $full -Recurse -Force}
}