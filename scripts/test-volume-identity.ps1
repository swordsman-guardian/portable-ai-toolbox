[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
$cases = @(
    @{ expected=@{VolumeGuid='a';Serial='1'}; actual=@{VolumeGuid='a';Serial='1'}; match=$true },
    @{ expected=@{VolumeGuid='a';Serial='1'}; actual=@{VolumeGuid='b';Serial='1'}; match=$false },
    @{ expected=@{VolumeGuid='a';Serial='1'}; actual=@{VolumeGuid='a';Serial='2'}; match=$false },
    @{ expected=@{VolumeGuid='a'}; actual=@{VolumeGuid='A'}; match=$true },
    @{ expected=@{Serial='1'}; actual=@{Serial='1'}; match=$true },
    @{ expected=@{VolumeGuid='a'}; actual=@{Serial='1'}; match=$false },
    @{ expected=@{Serial='1'}; actual=@{VolumeGuid='a'}; match=$false },
    @{ expected=@{}; actual=@{}; match=$false }
)
foreach ($case in $cases) {
    $got = Test-VolumeIdentityMatch -Expected ([pscustomobject]$case.expected) -Actual ([pscustomobject]$case.actual)
    if ($got -ne $case.match) { throw '卷身份比较不符合预期' }
}
Write-Host "卷身份比较通过：$($cases.Count) 项，无共同标识时拒绝认作原卷。"
exit 0
