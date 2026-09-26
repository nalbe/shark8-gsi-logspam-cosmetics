# Build one flashable KernelSU module zip per module directory.
#
#   powershell -File build.ps1                        # every module
#   powershell -File build.ps1 -Module libpowerhal-noise
#
# Layout inside the zip is flat, module.prop at the root, same as the
# pre-split release zips: the directory name is irrelevant to KernelSU, the
# module id in module.prop is what identifies it on the device.
#
# The repo-only files (README.md, apply.sh, revert.sh, the patch_*.ps1
# patchers, tools/) are not part of the module and stay out of the zip.
# Module scripts ship 0755 and everything else 0644, in the Unix mode of the
# ZIP external attributes with the version-made-by host byte set to Unix -
# without both, KernelSU silently skips post-fs-data.sh and service.sh.
# The four vendor payloads are md5-checked before the zip is written, so a
# wrong or half-patched file in a module directory fails here and not on the
# phone.

[CmdletBinding()]
param(
    [string[]]$Module
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Join-Path $root 'release'

$expected = @{
    'mtk-power-setmode'      = @{ 'vendor/lib64/android.hardware.power-service-mediatek.so' = 'a52fb102917c13c0b15ed83a13598394' }
    'libpowerhal-noise'      = @{ 'vendor/lib64/libpowerhal.so'                          = '58bd610b542ba4ca0747718d1189312a' }
    'eara-io-scene-detector' = @{ 'vendor/lib64/lib_eara_io_scndet.so'                    = '71af817be84f670a088ce439db96e18c' }
    'netdagent-iptables'     = @{ 'vendor/bin/netdagent'                                 = 'f58dbc8877c401ed4d2bcf9d0436bb42' }
}

# repo-only files, never flashed
$skip = @('README.md', 'apply.sh', 'revert.sh')

# Unix st_mode for the ZIP external attributes: 0x8000 regular file | perms,
# 0755 on the module scripts, 0644 on everything else. The mode lives in the
# upper 16 bits of the external attributes field.
$modeExec = 0x81ED
$modeFile = 0x81A4

# .NET writes every archive as "made by MS-DOS", and a reader that believes that
# ignores the Unix mode above and falls back to 0644 - at which point KernelSU
# silently skips post-fs-data.sh and service.sh. Flip the version-made-by host
# byte of every central directory entry to Unix so the mode is honored.
function Set-ZipUnixHost([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $min = [Math]::Max(0, $bytes.Length - 65557)
    $eocd = -1
    for ($i = $bytes.Length - 22; $i -ge $min; $i--) {
        if ($bytes[$i] -eq 0x50 -and $bytes[$i+1] -eq 0x4B -and $bytes[$i+2] -eq 0x05 -and $bytes[$i+3] -eq 0x06) { $eocd = $i; break }
    }
    if ($eocd -lt 0) { throw "EOCD record not found in $Path" }
    $count = [BitConverter]::ToUInt16($bytes, $eocd + 10)
    $offset = [BitConverter]::ToUInt32($bytes, $eocd + 16)
    for ($n = 0; $n -lt $count; $n++) {
        if (-not ($bytes[$offset] -eq 0x50 -and $bytes[$offset+1] -eq 0x4B -and $bytes[$offset+2] -eq 0x01 -and $bytes[$offset+3] -eq 0x02)) {
            throw "Bad central directory header at offset $offset"
        }
        $bytes[$offset + 5] = 3  # version-made-by high byte: host = Unix
        $fnLen = [BitConverter]::ToUInt16($bytes, $offset + 28)
        $exLen = [BitConverter]::ToUInt16($bytes, $offset + 30)
        $cmLen = [BitConverter]::ToUInt16($bytes, $offset + 32)
        $offset += 46 + $fnLen + $exLen + $cmLen
    }
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Get-ModuleFiles([string]$dir) {
    $files = @()
    foreach ($f in Get-ChildItem -LiteralPath $dir -File) {
        if ($skip -contains $f.Name) { continue }
        if ($f.Extension -eq '.ps1') { continue }
        $files += ,$f
    }
    $vendor = Join-Path $dir 'vendor'
    if (Test-Path -LiteralPath $vendor) {
        $files += @(Get-ChildItem -LiteralPath $vendor -Recurse -File)
    }
    return $files
}

$dirs = if ($Module) {
    $Module
} else {
    Get-ChildItem -LiteralPath $root -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'module.prop') } |
        ForEach-Object { $_.Name } |
        Sort-Object
}

if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}

$failed = $false
foreach ($d in $dirs) {
    $dir = Join-Path $root $d
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'module.prop'))) {
        Write-Host "[!] $d has no module.prop, skipped" -ForegroundColor Red
        $failed = $true
        continue
    }

    $prop = @{}
    foreach ($line in Get-Content -LiteralPath (Join-Path $dir 'module.prop')) {
        if ($line -match '^([^=]+)=(.*)$') { $prop[$matches[1]] = $matches[2] }
    }
    $id = $prop['id']
    $ver = $prop['version']
    if (-not $id) {
        Write-Host "[!] $d/module.prop has no id=" -ForegroundColor Red
        $failed = $true
        continue
    }

    $files = @(Get-ModuleFiles $dir)

    if ($expected.ContainsKey($d)) {
        foreach ($rel in $expected[$d].Keys) {
            $f = Join-Path $dir ($rel -replace '/', '\')
            if (-not (Test-Path -LiteralPath $f)) {
                Write-Host "[!] $d : missing $rel" -ForegroundColor Red
                $failed = $true
                continue
            }
            $md5 = (Get-FileHash -LiteralPath $f -Algorithm MD5).Hash.ToLower()
            if ($md5 -ne $expected[$d][$rel]) {
                Write-Host "[!] $d : $rel md5 $md5, want $($expected[$d][$rel])" -ForegroundColor Red
                $failed = $true
            } else {
                Write-Host ("    ok {0}  {1}" -f $md5, $rel)
            }
        }
    }

    $zipName = "shark8_${id}_${ver}.zip"
    $zipPath = Join-Path $outDir $zipName
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew)
    $archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($dir.Length + 1) -replace '\\', '/'
            # 0755 on the module scripts and on the vendor daemon, 0644 on the
            # rest. The three libraries are dlopen'd and only have to be
            # readable, but netdagent is an init service: at 0644 init cannot
            # exec it and it crash-loops with "cannot execv ... Permission
            # denied", so its mode is not optional.
            $exec = ($f.Extension -eq '.sh') -or ($rel -like 'vendor/bin/*')
            $mode = if ($exec) { $modeExec } else { $modeFile }
            $entry = $archive.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.ExternalAttributes = [int]($mode -shl 16)
            # CreateEntry stamps DateTime.Now, which would make every build a
            # different zip. Keep the source file's mtime so the zip is
            # reproducible and can be compared against a released one.
            $entry.LastWriteTime = $f.LastWriteTime
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $stream = $entry.Open()
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
    } finally {
        $archive.Dispose()
        $fs.Dispose()
    }
    Set-ZipUnixHost $zipPath

    $zmd5 = (Get-FileHash -LiteralPath $zipPath -Algorithm MD5).Hash.ToLower()
    $zlen = (Get-Item -LiteralPath $zipPath).Length
    Write-Host ("[+] {0,-22} {1,-42} {2,7} bytes  md5 {3}" -f $d, $zipName, $zlen, $zmd5) -ForegroundColor Green
}

if ($failed) { exit 1 }
exit 0
