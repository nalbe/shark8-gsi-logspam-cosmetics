# Rebuild the patched MTK lib_eara_io_scndet library from the stock one.
#
#   powershell -File patch_libeara.ps1 -In stock.so -Out patched.so
#
# Target: /vendor/lib64/lib_eara_io_scndet.so
# Stock md5 54218e4a8c26e09645c5d35f622ad4fd (19808 bytes).
#
# Silences the two INFO firehoses that eara_io_service produces while a tagged
# (MICtx) app loads assets (~120 lines per game load):
#
#   I eara_io@boost: [eara_io_boost] eara_io_boost %d , ta %d
#   I eara_io@eval:  [eara_io_eval] r2 %d , r %d , w2 %d , w %d , w+r %d , ...
#
# The original justification for patching instead of using persist.log.tag.*
# ("@ is illegal in a property name") is wrong - the stock image ships
# persist.log.tag.mtkpower@impl=I and setting it to V works. This patch is kept
# because it is the variant verified on device; the tag route
# (persist.log.tag.eara_io@boost=E) is untested against the stock library.
# Only the INFO calls are dropped: the ERROR paths of the same functions
# ("no data found", perfLockAcq/dlopen failures) keep logging, and all state
# updates before the calls stay.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$In,
    [string]$Out
)

$ErrorActionPreference = 'Stop'

if (-not $Out) { $Out = "$In.patched" }
if (-not (Test-Path -LiteralPath $In)) { throw "input not found: $In" }

$nop = [uint32]::Parse('D503201F', [Globalization.NumberStyles]::HexNumber)

# .rodata here is at file offset == vaddr, so offsets below are both.
$fmtBoost = [Text.Encoding]::ASCII.GetBytes("[%s] eara_io_boost %d , ta %d")
$fmtEval  = [Text.Encoding]::ASCII.GetBytes("[%s] r2 %d , r %d , w2 %d , w %d , w+r %d , w2+r2 %d , w3+r3 %d")
$tagBoost = [Text.Encoding]::ASCII.GetBytes("eara_io@boost")
$tagEval  = [Text.Encoding]::ASCII.GetBytes("eara_io@eval")

$fmtBoostOff = 0x10F8
$fmtEvalOff  = 0x11B0
$tagBoostOff = 0x14A0
$tagEvalOff  = 0x134B

# bl __android_log_print@plt (0x3830) call sites that carry those formats.
# 0x358C: boost level 0 path (w0 = 4 INFO, w4/w5 = 0)   - the "boost 0 , ta 0" flood
# 0x3688: boost level 1..4 path (w0 = 4 INFO, w4 = level, w5 = ta)
# 0x2CF8: eval path (w0 = 4 INFO)
$edits = @(
    @{ Off = 0x358C; From = [uint32]::Parse('940000A9', [Globalization.NumberStyles]::HexNumber); To = $nop;
       What = 'bl log (boost, level 0 path)' }
    @{ Off = 0x3688; From = [uint32]::Parse('9400006A', [Globalization.NumberStyles]::HexNumber); To = $nop;
       What = 'bl log (boost, level 1..4 path)' }
    @{ Off = 0x2CF8; From = [uint32]::Parse('940002CE', [Globalization.NumberStyles]::HexNumber); To = $nop;
       What = 'bl log (eval)' }
)

# context instructions that prove we are inside the expected functions
$context = @(
    @{ Off = 0x3580; Val = [uint32]::Parse('52800080', [Globalization.NumberStyles]::HexNumber); What = 'mov w0, #0x4 (INFO)' }
    @{ Off = 0x3680; Val = [uint32]::Parse('52800080', [Globalization.NumberStyles]::HexNumber); What = 'mov w0, #0x4 (INFO)' }
    @{ Off = 0x2CE0; Val = [uint32]::Parse('52800080', [Globalization.NumberStyles]::HexNumber); What = 'mov w0, #0x4 (INFO)' }
    @{ Off = 0x2CFC; Val = [uint32]::Parse('B9800328', [Globalization.NumberStyles]::HexNumber); What = 'ldrsw x8, [x25] (after the eval bl)' }
)

$bytes = [IO.File]::ReadAllBytes($In)
if ($bytes.Length -lt 0x2000) { throw "input too small, not this library: $($bytes.Length) bytes" }

function Assert-Bytes([byte[]]$hay, [int]$off, [byte[]]$needle, [string]$what) {
    if ($off + $needle.Length -gt $hay.Length) { throw "offset 0x$('{0:X}' -f $off) out of range ($what)" }
    for ($i = 0; $i -lt $needle.Length; $i++) {
        if ($hay[$off + $i] -ne $needle[$i]) {
            throw ("{0} mismatch at 0x{1:X}: got '{2}'" -f $what, ($off + $i), [char]$hay[$off + $i])
        }
    }
}

Assert-Bytes $bytes $fmtBoostOff $fmtBoost 'boost format string'
Assert-Bytes $bytes $fmtEvalOff  $fmtEval  'eval format string'
Assert-Bytes $bytes $tagBoostOff $tagBoost 'boost tag'
Assert-Bytes $bytes $tagEvalOff  $tagEval  'eval tag'

foreach ($c in $context) {
    $cur = [BitConverter]::ToUInt32($bytes, [int]$c.Off)
    if ($cur -ne $c.Val) {
        throw ("offset 0x{0:X} mismatch: expected 0x{1:X}, got 0x{2:X} - wrong stock build?" -f $c.Off, $c.Val, $cur)
    }
}

foreach ($e in $edits) {
    $off = [int]$e.Off
    $cur = [BitConverter]::ToUInt32($bytes, $off)
    if ($cur -ne $e.From) {
        throw ("offset 0x{0:X} mismatch: expected 0x{1:X}, got 0x{2:X} - wrong stock build?" -f $off, $e.From, $cur)
    }
    [BitConverter]::GetBytes([uint32]$e.To).CopyTo($bytes, $off)
    Write-Host ("[*] 0x{0:X}  0x{1:X} -> 0x{2:X}  {3}" -f $off, $cur, $e.To, $e.What)
}

[IO.File]::WriteAllBytes($Out, $bytes)

Write-Host ("[+] wrote {0} ({1} bytes)" -f $Out, $bytes.Length)
Write-Host ("    md5    {0}" -f (Get-FileHash -LiteralPath $Out -Algorithm MD5).Hash.ToLower())
Write-Host ("    sha256 {0}" -f (Get-FileHash -LiteralPath $Out -Algorithm SHA256).Hash.ToLower())
