[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('NodeToPowerShell','PowerShellToNode')][string]$Mode,[Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Source)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'cc-switch-encrypted-store.ps1')
$password=New-Object Security.SecureString
foreach($character in $env:CC_TEST_PASSWORD.ToCharArray()){$password.AppendChar($character)}
$password.MakeReadOnly()
$session=$null
try {
    $traversalRejected=$false
    try { Assert-CcEncRelativePath 'harness/cc-switch/../../../outside.txt' } catch { $traversalRejected=$true }
    if(-not $traversalRejected){throw 'Archive traversal path was accepted.'}
    $session=Open-CcEncryptedStoreSession -StickRoot $Root -Password $password
    $snap=Get-CcEncryptedStoreStatus -StickRoot $Root
    if($Mode -eq 'NodeToPowerShell') {
        if(-not $snap.CurrentRevision){throw 'Interop fixture has no committed Node generation.'}
        $verified=Get-CcEncVerifiedZip -Store (Get-CcEncPaths $Root).Store -Revision $snap.CurrentRevision -Key $session.DataKey
        try {
            $entry=$verified.Zip.GetEntry('harness/cc-switch/claude/settings.json')
            if(-not $entry){throw 'PowerShell could not read the Node-authored ZIP inventory.'}
            $reader=New-Object IO.StreamReader($entry.Open(),(New-Object Text.UTF8Encoding($false,$true)))
            try {$doc=$reader.ReadToEnd()|ConvertFrom-Json -ErrorAction Stop} finally {$reader.Dispose()}
            if($doc.env.ANTHROPIC_AUTH_TOKEN -notmatch '^SYNTHETIC-'){throw 'PowerShell could not read the Node-authored provider fixture.'}
        } finally {$verified.Zip.Dispose();$verified.Stream.Dispose();[Array]::Clear($verified.Plain,0,$verified.Plain.Length)}
    }
    if($Mode -eq 'NodeToPowerShell') {
        $settings=Join-Path $Source 'harness\cc-switch\claude\settings.json'
        $doc=Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
        $doc.env.ANTHROPIC_AUTH_TOKEN='SYNTHETIC-PS-UPDATED-3ca1'
        [IO.File]::WriteAllText($settings,(ConvertTo-Json -InputObject $doc -Depth 8 -Compress),(New-Object Text.UTF8Encoding($false)))
        $null=Save-CcEncryptedSnapshot -Session $session -SourceRoot $Source -StoppedOnly
    } else {
        $null=Save-CcEncryptedSnapshot -Session $session -SourceRoot $Source -StoppedOnly
    }
    'PASS: PowerShell interoperability'
} finally { if($session){Close-CcEncryptedStoreSession $session} }
