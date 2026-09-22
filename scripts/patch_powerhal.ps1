# Rebuild the patched MTK power HAL library from the stock one.
#
#   powershell -File patch.ps1 -In stock.so -Out patched.so
#
# Target: /vendor/lib64/android.hardware.power-service-mediatek.so
# Stock md5 40aea46435089ab1e2fc002d67f8ec2d (19776 bytes,
# build id 0a3fb0b555d78fc46f077a86c86d1c5e).
#
# Silences the per-second "[setMode] type:6, enabled:N" / "[setMode] unknown type"
# spam produced by aidl::android::hardware::power::impl::mediatek::Power::setMode
# when the GSI surfaceflinger asks for Mode::EXPENSIVE_RENDERING (=6), which this
# vendor HAL does not implement.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$In,
    [string]$Out
)

$ErrorActionPreference = 'Stop'

if (-not $Out) { $Out = "$In.patched" }
if (-not (Test-Path -LiteralPath $In)) { throw "input not found: $In" }

# function Power::setMode @ .text 0x31A8 (size 0x1E4)
#   entry INFO log "[%s] type:%d, enabled:%d" .... 0x31F0
#   switch dispatch (b.hi to the unknown-type arm) 0x31FC
#   unknown-type arm ............................. 0x3320, logs at 0x336C
#   AStatus_newOk tail (return OK) ............... 0x3370
# rodata dispatch table @ 0x1850, one byte per mode, index = mode - 2,
# target = 0x3218 + byte * 4; 0x42 = 0x3320 (unknown type).
$nop = [uint32]::Parse('D503201F', [Globalization.NumberStyles]::HexNumber)
$ok  = [uint32]::Parse('54000BA8', [Globalization.NumberStyles]::HexNumber)

# offset, kind, expected stock value, patched value, description
$edits = @(
    @{ Off = 0x31F0; Kind = 'u32'; From = [uint32]::Parse('94000288', [Globalization.NumberStyles]::HexNumber); To = $nop;
       What = 'nop the entry "[%s] type:%d, enabled:%d" log call' }
    @{ Off = 0x31FC; Kind = 'u32'; From = [uint32]::Parse('54000928', [Globalization.NumberStyles]::HexNumber); To = $ok;
       What = 'b.hi unknown-type -> b.hi AStatus_newOk (silent OK)' }
    @{ Off = 0x1852; Kind = 'u8';  From = 0x42; To = 0x56;
       What = 'jump table: mode 4 (VR) -> AStatus_newOk' }
    @{ Off = 0x1854; Kind = 'u8';  From = 0x42; To = 0x56;
       What = 'jump table: mode 6 (EXPENSIVE_RENDERING) -> AStatus_newOk' }
)

$bytes = [IO.File]::ReadAllBytes($In)
if ($bytes.Length -lt 0x31FC + 4) { throw "input too small, not this library: $($bytes.Length) bytes" }

foreach ($e in $edits) {
    $off = [int]$e.Off
    if ($e.Kind -eq 'u32') {
        $cur = [BitConverter]::ToUInt32($bytes, $off)
    } else {
        $cur = [uint32]$bytes[$off]
    }
    if ($cur -ne $e.From) {
        throw ("offset 0x{0:X} mismatch: expected 0x{1:X}, got 0x{2:X} - wrong stock build?" -f $off, $e.From, $cur)
    }
    if ($e.Kind -eq 'u32') {
        [BitConverter]::GetBytes([uint32]$e.To).CopyTo($bytes, $off)
    } else {
        $bytes[$off] = [byte]$e.To
    }
    Write-Host ("[*] 0x{0:X}  0x{1:X} -> 0x{2:X}  {3}" -f $off, $e.From, $e.To, $e.What)
}

[IO.File]::WriteAllBytes($Out, $bytes)

$md5 = (Get-FileHash -LiteralPath $Out -Algorithm MD5).Hash.ToLower()
$sha = (Get-FileHash -LiteralPath $Out -Algorithm SHA256).Hash.ToLower()
Write-Host ("[+] wrote {0} ({1} bytes)" -f $Out, $bytes.Length)
Write-Host "    md5    $md5"
Write-Host "    sha256 $sha"
if ($md5 -ne 'a52fb102917c13c0b15ed83a13598394') {
    Write-Warning "md5 differs from the released build (a52fb102917c13c0b15ed83a13598394)"
}
