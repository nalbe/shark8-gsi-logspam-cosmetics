# Rebuild the patched MTK netdagent daemon from the stock one.
#
#   powershell -File patch_netdagent.ps1 -In netdagent -Out netdagent.patched
#
# Target: /vendor/bin/netdagent
# Stock md5 6e3f6b430386eb032715038bf7544120 (55616 bytes).
#
# Silences the two ERROR lines the daemon itself prints on every network boost
# that libpowerhal asks for:
#
#   E NetdagentIptables: exec() res=0, status=256
#   E NetdagentService: run command %s failed
#
# libPowerHal's netd_* hints forward "priority_set_uid" commands over the
# (missing) netdagent socket; the daemon runs them by exec'ing
# /system/bin/iptables-wrapper-1.0, which exits with status 1 on this GSI, so
# the wrapper logs twice - once in the exec helper, once in the run_* caller.
# Status 256 is waitpid's raw value for exit code 1; there is no AVC denial and
# no other diagnostic in that path, only these two lines.
#
# Where they come from:
#
#   0x56E0  bl __android_log_print   x2 = 0x2AAF "run command %s failed",
#                                    x1 = 0x2F5D "NetdagentService"
#                                    -> falls through to mov w22, #-1
#   0xB0BC  bl __android_log_print   x2 = 0x24BC "exec() res=%d, status=%d",
#                                    x1 = 0x3639 "NetdagentIptables",
#                                    w3/w4 = res/status
#                                    -> falls through to ldrb w8, [sp, #0x18]
#
# Fix: nop both bl calls. Each site falls through to code that touches no
# register the log call could have defined, so nothing but the print is lost;
# both messages are printed with format offsets referenced exactly once in the
# whole binary (checked with llvm-objdump -d). The daemon keeps running its
# iptables invocation and keeps returning the same status - only the two lines
# disappear. This hides a real failure of this GSI/vendor mix, it does not fix
# it: net hints stay dead as long as netdagent.rc ships its socket line
# commented out.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$In,
    [string]$Out
)

$ErrorActionPreference = 'Stop'

if (-not $Out) { $Out = "$In.patched" }
if (-not (Test-Path -LiteralPath $In)) { throw "input not found: $In" }

$stockMd5 = '6e3f6b430386eb032715038bf7544120'
$stockLen = 55616
$logPlt = 0xB620            # __android_log_print@plt (.text+0x6620)

$nop = [uint32]::Parse('D503201F', [Globalization.NumberStyles]::HexNumber)

# offset, expected stock bl word, description
$nops = @(
    @{ Off = 0x56E0; From = '940017D0'; What = 'run command %s failed (NetdagentService)' }
    @{ Off = 0xB0BC; From = '94000159'; What = 'exec() res=%d, status=%d (NetdagentIptables)' }
)

# the literals above, used as a build guard (file offset == virtual address)
$msgs = @(
    @{ Off = 0x24BC; Text = 'exec() res=%d, status=%d' }
    @{ Off = 0x2AAF; Text = 'run command %s failed' }
    @{ Off = 0x2F5D; Text = 'NetdagentService' }
    @{ Off = 0x3639; Text = 'NetdagentIptables' }
)

$bytes = [IO.File]::ReadAllBytes($In)
if ($bytes.Length -ne $stockLen) { throw "input is $($bytes.Length) bytes, expected $stockLen - wrong stock build?" }

$md5 = (Get-FileHash -LiteralPath $In -Algorithm MD5).Hash.ToLower()
if ($md5 -ne $stockMd5) { throw "input md5 $md5, expected $stockMd5 - wrong stock build?" }
Write-Host "[*] stock build confirmed (md5 $md5)"

foreach ($m in $msgs) {
    $off = [int]$m.Off
    $cur = [Text.Encoding]::ASCII.GetString($bytes, $off, $m.Text.Length)
    if ($cur -ne $m.Text) { throw ("literal at 0x{0:X} mismatch: expected '$($m.Text)', got '$cur' - wrong stock build?" -f $off) }
}
Write-Host ("[*] literal guard OK ({0} strings)" -f $msgs.Count)

foreach ($e in $nops) {
    $off = [int]$e.Off
    $want = [uint32]::Parse($e.From, [Globalization.NumberStyles]::HexNumber)
    $cur = [BitConverter]::ToUInt32($bytes, $off)
    if ($cur -ne $want) { throw ("offset 0x{0:X} mismatch: expected 0x{1:X}, got 0x{2:X} - wrong stock build?" -f $off, $want, $cur) }
    # decode bl imm26 and require the call target to be __android_log_print@plt
    $imm = $cur -band 0x03FFFFFF
    if ($imm -band 0x02000000) { $imm -= 0x04000000 }
    $target = $off + 4 * $imm
    if ($target -ne $logPlt) { throw ("offset 0x{0:X}: bl target 0x{1:X} is not __android_log_print@plt - wrong stock build?" -f $off, $target) }
    [BitConverter]::GetBytes([uint32]$nop).CopyTo($bytes, $off)
    Write-Host ("[*] 0x{0:X}  0x{1:X} -> nop  {2}" -f $off, $cur, $e.What)
}

[IO.File]::WriteAllBytes($Out, $bytes)

$md5 = (Get-FileHash -LiteralPath $Out -Algorithm MD5).Hash.ToLower()
$sha = (Get-FileHash -LiteralPath $Out -Algorithm SHA256).Hash.ToLower()
Write-Host ("[+] wrote {0} ({1} bytes)" -f $Out, $bytes.Length)
Write-Host "    md5    $md5"
Write-Host "    sha256 $sha"
