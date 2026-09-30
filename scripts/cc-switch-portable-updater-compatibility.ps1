[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Get-CcPortablePeUInt16([byte[]]$Bytes,[long]$Offset) {
    if($Offset -lt 0 -or $Offset+2 -gt $Bytes.LongLength){throw 'PE structure is truncated.'}
    [BitConverter]::ToUInt16($Bytes,[int]$Offset)
}
function Get-CcPortablePeUInt32([byte[]]$Bytes,[long]$Offset) {
    if($Offset -lt 0 -or $Offset+4 -gt $Bytes.LongLength){throw 'PE structure is truncated.'}
    [BitConverter]::ToUInt32($Bytes,[int]$Offset)
}
function Get-CcPortablePeUInt64([byte[]]$Bytes,[long]$Offset) {
    if($Offset -lt 0 -or $Offset+8 -gt $Bytes.LongLength){throw 'PE structure is truncated.'}
    [BitConverter]::ToUInt64($Bytes,[int]$Offset)
}
function ConvertTo-CcPortablePeFileOffset([uint32]$Rva,$Sections,[long]$FileLength) {
    foreach($section in $Sections){
        [long]$span=[Math]::Max([long]$section.VirtualSize,[long]$section.RawSize)
        if([long]$Rva -ge [long]$section.VirtualAddress -and [long]$Rva -lt ([long]$section.VirtualAddress+$span)){
            [long]$offset=[long]$section.RawOffset+([long]$Rva-[long]$section.VirtualAddress)
            if($offset -lt 0 -or $offset -ge $FileLength){throw 'PE RVA points outside the executable file.'}
            return $offset
        }
    }
    throw ('PE RVA '+$Rva+' does not belong to a file-backed section (file length '+$FileLength+').')
}
function Read-CcPortablePeAscii([byte[]]$Bytes,[long]$Offset,[int]$MaxLength=512) {
    if($Offset -lt 0 -or $Offset -ge $Bytes.LongLength){throw 'PE import string is outside the executable file.'}
    $end=[Math]::Min($Bytes.LongLength,$Offset+$MaxLength)
    $chars=New-Object 'System.Collections.Generic.List[char]'
    for([long]$i=$Offset;$i -lt $end;$i++){
        $b=$Bytes[[int]$i];if($b -eq 0){return (-join $chars.ToArray())};if($b -gt 0x7f){throw 'PE import string is not ASCII.'};$chars.Add([char]$b)
    }
    throw 'PE import string is not terminated within its bound.'
}

function Test-CcPortableUpdaterCandidateCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedSha256
    )
    $result=[ordered]@{Compatible=$false;Machine='Unknown';ImportsCreateProcessW=$false;ImportsGetFinalPathNameByHandleW=$false;ImportsShellExecute=$false;Reason=''}
    try{
        Assert-CcPortableUpdateNoReparse $ExecutablePath
        $item=Get-Item -LiteralPath $ExecutablePath -Force -ErrorAction Stop
        if($item.PSIsContainer -or $item.Length -lt 512 -or $item.Length -gt 200MB){throw 'Candidate executable length is outside the bounded PE range.'}
        $bytes=[IO.File]::ReadAllBytes($ExecutablePath)
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$actualHash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
        if(-not [string]::Equals($actualHash,$ExpectedSha256,[StringComparison]::OrdinalIgnoreCase)){throw 'Candidate executable hash differs from its verified slot manifest.'}
        if((Get-CcPortablePeUInt16 $bytes 0) -ne 0x5a4d){throw 'Candidate executable has no DOS header.'}
        [long]$peOffset=Get-CcPortablePeUInt32 $bytes 0x3c
        if($peOffset -lt 0x40 -or $peOffset+24 -gt $bytes.LongLength -or (Get-CcPortablePeUInt32 $bytes $peOffset) -ne 0x00004550){throw 'Candidate executable has an invalid PE header.'}
        $machine=Get-CcPortablePeUInt16 $bytes ($peOffset+4)
        if($machine -ne 0x8664){throw 'Candidate executable is not x64 PE.'}
        $result.Machine='x64'
        $sectionCount=Get-CcPortablePeUInt16 $bytes ($peOffset+6)
        $optionalSize=Get-CcPortablePeUInt16 $bytes ($peOffset+20)
        $optional=$peOffset+24
        if($sectionCount -lt 1 -or $sectionCount -gt 96 -or $optionalSize -lt 128 -or $optional+$optionalSize+([long]$sectionCount*40) -gt $bytes.LongLength){throw 'Candidate executable has invalid section metadata.'}
        if((Get-CcPortablePeUInt16 $bytes $optional) -ne 0x20b){throw 'Candidate executable is not PE32+ x64.'}
        $directoryCount=Get-CcPortablePeUInt32 $bytes ($optional+108)
        if($directoryCount -lt 2){throw 'Candidate executable has no import directory.'}
        [uint32]$importRva=Get-CcPortablePeUInt32 $bytes ($optional+120)
        [uint32]$importSize=Get-CcPortablePeUInt32 $bytes ($optional+124)
        if($importRva -eq 0 -or $importSize -lt 20 -or $importSize -gt 16MB){throw 'Candidate executable import directory is empty or out of bounds.'}
        $sections=New-Object 'System.Collections.Generic.List[object]'
        $sectionOffset=$optional+$optionalSize
        for($i=0;$i -lt $sectionCount;$i++){
            $o=$sectionOffset+($i*40)
            $virtualSize=Get-CcPortablePeUInt32 $bytes ($o+8);$virtualAddress=Get-CcPortablePeUInt32 $bytes ($o+12)
            $rawSize=Get-CcPortablePeUInt32 $bytes ($o+16);$rawOffset=Get-CcPortablePeUInt32 $bytes ($o+20)
            if([long]$rawOffset+[long]$rawSize -gt $bytes.LongLength){throw 'Candidate executable section exceeds its file bounds.'}
            $sections.Add([pscustomobject]@{VirtualSize=$virtualSize;VirtualAddress=$virtualAddress;RawSize=$rawSize;RawOffset=$rawOffset})
        }
        [long]$descriptorOffset=ConvertTo-CcPortablePeFileOffset $importRva $sections $bytes.LongLength
        $descriptors=[Math]::Min([long]($importSize/20),4096)
        $foundTerminator=$false
        for([long]$d=0;$d -lt $descriptors;$d++){
            $entry=$descriptorOffset+($d*20)
            if($entry+20 -gt $bytes.LongLength){throw 'Candidate executable import descriptors are truncated.'}
            [uint32]$originalThunk=Get-CcPortablePeUInt32 $bytes ($entry+0)
            [uint32]$nameRva=Get-CcPortablePeUInt32 $bytes ($entry+12)
            [uint32]$firstThunk=Get-CcPortablePeUInt32 $bytes ($entry+16)
            if($originalThunk -eq 0 -and $nameRva -eq 0 -and $firstThunk -eq 0){$foundTerminator=$true;break}
            if($nameRva -eq 0 -or $firstThunk -eq 0){throw 'Candidate executable import descriptor is malformed.'}
            try{$dllOffset=ConvertTo-CcPortablePeFileOffset $nameRva $sections $bytes.LongLength}catch{throw ('Import descriptor '+$d+' at offset '+$entry+' DLL-name RVA '+$nameRva+' is invalid. '+$_.Exception.Message)}
            $dll=Read-CcPortablePeAscii $bytes $dllOffset 260
            if($dll -notin @('KERNEL32.dll','KERNELBASE.dll','SHELL32.dll')){continue}
            [uint32]$thunkRva=if($originalThunk){$originalThunk}else{$firstThunk}
            try{[long]$thunkOffset=ConvertTo-CcPortablePeFileOffset $thunkRva $sections $bytes.LongLength}catch{throw ('Import thunk table RVA '+$thunkRva+' is invalid for '+$dll+'. '+$_.Exception.Message)}
            for($t=0;$t -lt 16384;$t++){
                $value=Get-CcPortablePeUInt64 $bytes ($thunkOffset+($t*8))
                if($value -eq 0){break}
                if(($value -band 0x8000000000000000) -ne 0){continue}
                if($value -gt [uint64][uint32]::MaxValue){throw ('Candidate executable import name RVA is invalid: '+$value+' (thunk RVA '+$thunkRva+', file offset '+$thunkOffset+', index '+$t+')')}
                try{$importByName=ConvertTo-CcPortablePeFileOffset ([uint32]$value) $sections $bytes.LongLength}catch{throw ('Import thunk for '+$dll+' at index '+$t+' contains invalid name RVA '+$value+'. '+$_.Exception.Message)}
                $symbol=Read-CcPortablePeAscii $bytes ($importByName+2) 256
                if($dll -in @('KERNEL32.dll','KERNELBASE.dll') -and $symbol -ceq 'CreateProcessW'){$result.ImportsCreateProcessW=$true}
                if($dll -in @('KERNEL32.dll','KERNELBASE.dll') -and $symbol -ceq 'GetFinalPathNameByHandleW'){$result.ImportsGetFinalPathNameByHandleW=$true}
                if($dll -ceq 'SHELL32.dll' -and $symbol -in @('ShellExecuteW','ShellExecuteExW')){$result.ImportsShellExecute=$true}
            }
        }
        if(-not $foundTerminator){throw 'Candidate executable import directory has no bounded terminator.'}
        if(-not $result.ImportsCreateProcessW){throw 'Candidate executable does not import the CreateProcessW hook target.'}
        if(-not $result.ImportsGetFinalPathNameByHandleW){throw 'Candidate executable does not import the GetFinalPathNameByHandleW hook target required by the updater shim.'}
        $result.Compatible=$true;$result.Reason='x64 PE imports the required CreateProcessW and GetFinalPathNameByHandleW hooks; this structural check does not guarantee future UI or updater semantics.'
    }catch{$result.Reason=$_.Exception.Message}
    return [pscustomobject]$result
}
