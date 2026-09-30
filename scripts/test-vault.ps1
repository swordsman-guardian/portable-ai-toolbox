# Synthetic-only tests for the portable credential vault.
param([switch]$Quick)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vault.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ('vault-test-' + [Guid]::NewGuid().ToString('N'))
$file = Join-Path $root 'credentials.vault.json'
New-Item -ItemType Directory -Path $root | Out-Null
$password = ConvertTo-SecureString 'synthetic test master password' -AsPlainText -Force
$wrong = ConvertTo-SecureString 'wrong synthetic password' -AsPlainText -Force
$checks = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
    $script:checks++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-True $threw $Message
}

try {
    $createdRevision = Write-PortableVault -Path $file -Password $password -Secrets ([ordered]@{ synthetic_alpha = 'synthetic-value-one'; synthetic_beta = 'synthetic-value-two' }) -ExpectedRevision $null
    $first = Read-PortableVault -Path $file -Password $password
    Assert-True ($first.Revision -ceq $createdRevision) 'create/read revision matches'
    Assert-True ($first.Secrets['synthetic_alpha'] -ceq 'synthetic-value-one') 'synthetic secret round-trips'
    Assert-True ((Get-VaultStatus -Path $file).State -ceq 'Present') 'valid envelope reports Present'

    $originalBytes = [IO.File]::ReadAllBytes($file)
    $originalHash = Get-VaultRevision -Bytes $originalBytes
    Assert-Throws { Read-PortableVault -Path $file -Password $wrong } 'wrong password must fail'
    Assert-True ((Get-VaultRevision -Bytes ([IO.File]::ReadAllBytes($file))) -ceq $originalHash) 'wrong password leaves original file unchanged'

    $envObj = ([IO.File]::ReadAllText($file) | ConvertFrom-Json)
    $cipher = [Convert]::FromBase64String($envObj.ciphertext)
    $cipher[0] = $cipher[0] -bxor 1
    $envObj.ciphertext = [Convert]::ToBase64String($cipher)
    [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $envObj -Compress), (New-Object Text.UTF8Encoding($false)))
    $tamperedBytes = [IO.File]::ReadAllBytes($file)
    $tamperedHash = Get-VaultRevision -Bytes $tamperedBytes
    Assert-Throws { Read-PortableVault -Path $file -Password $password } 'modified ciphertext must fail authentication'
    Assert-True ((Get-VaultRevision -Bytes ([IO.File]::ReadAllBytes($file))) -ceq $tamperedHash) 'authentication failure leaves tampered original untouched'

    [IO.File]::WriteAllBytes($file, $originalBytes)
    $badMetadata = ([IO.File]::ReadAllText($file) | ConvertFrom-Json)
    $badMetadata.version = 99
    [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $badMetadata -Compress), (New-Object Text.UTF8Encoding($false)))
    Assert-True ((Get-VaultStatus -Path $file).State -ceq 'InvalidMetadata') 'unsupported metadata version is rejected by status'
    [IO.File]::WriteAllBytes($file, $originalBytes)
    $staleA = Read-PortableVault -Path $file -Password $password
    $staleB = Read-PortableVault -Path $file -Password $password
    $nextRevision = Write-PortableVault -Path $file -Password $password -Secrets ([ordered]@{ synthetic_alpha = 'new-value'; synthetic_beta = 'synthetic-value-two' }) -ExpectedRevision $staleA.Revision
    Assert-Throws { Write-PortableVault -Path $file -Password $password -Secrets $staleB.Secrets -ExpectedRevision $staleB.Revision } 'stale concurrent revision must be rejected'
    Assert-True ((Read-PortableVault -Path $file -Password $password).Secrets['synthetic_alpha'] -ceq 'new-value') 'stale write does not replace newer content'

    # Simulate interruption after staging the new file and moving the old file to backup.
    [IO.File]::Copy($file, $file + '.tmp', $true)
    [IO.File]::Delete($file + '.bak')
    [IO.File]::Move($file, $file + '.bak')
    Assert-Throws { Read-PortableVault -Path $file -Password $password } 'read must not choose a recovery candidate implicitly'
    $repair = Restore-PortableVault -Path $file -Password $password -Source Temp
    $recovered = Read-PortableVault -Path $file -Password $password
    Assert-True ($recovered.Revision -ceq $nextRevision) 'explicitly selected authenticated temp is installed after interruption'
    Assert-True ([IO.File]::Exists($file + '.bak')) 'previous encrypted revision remains recoverable as backup'
    Assert-True ([IO.File]::Exists($repair.PreservedSource) -and -not [IO.File]::Exists($file + '.tmp')) 'restore preserves temp under a non-blocking recovery name'
    $postRestoreRevision = Write-PortableVault -Path $file -Password $password -Secrets ([ordered]@{ synthetic_alpha = 'post-restore'; synthetic_beta = 'synthetic-value-two' }) -ExpectedRevision $recovered.Revision
    Assert-True ((Read-PortableVault -Path $file -Password $password).Revision -ceq $postRestoreRevision) 'writes can continue after explicit temp recovery'

    if (-not $Quick) {
        # Enforce the documented large-payload bound with synthetic data.
        $largeValue = 'A' * (32 * 1024 * 1024)
        $largeRevision = Write-PortableVault -Path $file -Password $password -Secrets ([ordered]@{ synthetic_zip_base64 = $largeValue }) -ExpectedRevision $postRestoreRevision
        $largeRead = Read-PortableVault -Path $file -Password $password
        Assert-True ($largeRead.Revision -ceq $largeRevision) '32 MiB synthetic payload fits and round-trips'
        Assert-True ($largeRead.Secrets['synthetic_zip_base64'].Length -eq $largeValue.Length) 'large payload length is preserved'
    }

    $recoveryOnly = Join-Path $root 'recovery-only.json'
    [IO.File]::WriteAllText($recoveryOnly + '.restore.tmp', 'synthetic recovery marker')
    $recoveryStatus = Get-VaultStatus -Path $recoveryOnly
    Assert-True ($recoveryStatus.State -ceq 'RecoveryRequired' -and $recoveryStatus.RestoreTempExists) 'restore-temp alone requires recovery'

    $outside = Join-Path $root 'junction-target'
    $inside = Join-Path $root 'junction-parent'
    New-Item -ItemType Directory -Path $outside,$inside | Out-Null
    $targetFile = Join-Path $outside 'must-not-be-touched.vault'
    $junction = Join-Path $inside 'linked'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    Assert-Throws { Get-VaultStatus -Path (Join-Path $junction 'must-not-be-touched.vault') } 'junction in parent path must be rejected'
    Assert-True (-not [IO.File]::Exists($targetFile)) 'parent junction rejection does not touch target'

    $sidecarVault = Join-Path $inside 'sidecar.vault'
    $sidecarJunction = $sidecarVault + '.bak'
    New-Item -ItemType Junction -Path $sidecarJunction -Target $outside | Out-Null
    Assert-Throws { Get-VaultStatus -Path $sidecarVault } 'junction recovery sidecar must be rejected'
    Assert-True (-not [IO.File]::Exists($targetFile)) 'sidecar junction rejection does not touch target'

    Write-Output "PASS: $checks vault checks completed using synthetic values only."
} finally {
    $password.Dispose(); $wrong.Dispose()
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
