# Rebuild the patched MTK libpowerhal library from the stock one.
#
#   powershell -File patch_libpowerhal.ps1 -In stock.so -Out patched.so
#
# Target: /vendor/lib64/libpowerhal.so
# Stock md5 eb618de9c44807d6ec1b21eb47ee5eb0 (275352 bytes).
#
# Silences three recurring sources of ERROR lines.
#
# (1) [getCPUFreq] error cid:2, nClusterNum:2
#
# getCPUFreq(int cid, int opp) @ .text 0x2812C returns -1 when cid is negative
# or >= nClusterNum. Something on this 2-cluster MT6789 still asks for cluster 2
# (a table entry left over from 3-cluster SoCs), so every power-table update that
# touches CLUSTER_2 logs the error (~10 lines per game load, 1 per screen
# off/on). The -1 is the vendor's normal "skip this update" path, so only the
# log call is dropped - the return value and all other error paths stay.
#
# (2) the two failing foreground-pid nodes written by perfNotifyAppState()
#
#   E libPowerHal: Could not open '/proc/driver/thermal/ta_fg_pid'
#   E libPowerHal: error : 2, No such file or directory
#   E libPowerHal: Could not open '/sys/module/ged/parameters/gx_top_app_pid'
#   E libPowerHal: error : 2, No such file or directory
#
# perfNotifyAppState(pack, act, state, pid, uid) @ .text 0x23D20, after the
# whitelist scan, hands the app pid to the two kernel drivers that implement the
# vendor's per-app policy:
#
#   0x24344 adrp x0, 0x12000 / 0x24348 add x0, x0, #0x287  -> ta_fg_pid
#   0x2436C adrp x0, 0x12000 / 0x24370 add x0, x0, #0x2a6  -> gx_top_app_pid
#   ... ldur w1, [x29, #-0x4] (the pid) / bl set_value(char const*, int)
#   0x24354/0x2437C cbnz w0: on success a "already written" byte is set so the
#   write is not retried. Both nodes are absent from this kernel (MTK's procfs
#   thermal controller is not built, and this GED generation has no pid
#   parameter), so set_value() fails on every notify and logs 2 ERROR lines per
#   path - 4 lines per game start, retried on every state=1.
#
# Fix: repoint both path literals at /dev/null. open() succeeds, the write is
# discarded, set_value() returns 0, the retry flag is set and nothing is logged.
# The writes could never succeed on this kernel, so there is no behavior change,
# and unlike nop'ing set_value()'s log calls this keeps the diagnostics of every
# other node write intact. Both literals are referenced exactly once in the whole
# library (checked with llvm-objdump -d), so nothing else is affected.
# Cost: if a future kernel does grow these nodes, the per-app hint stays off.
#
# (3) the whole netdagent error block
#
#   E libPowerHal: [NetdAgentCmd] dispatchNetdagentCmd failed
#   E libPowerHal: [netd_set_priority_uid] SetPriorityWithUID fail
#   ...
#
# netd_* and sdk_netd_* forward per-app network hints to the vendor netdagent
# service. On this GSI/vendor mix every single call fails: /vendor/etc/init/
# netdagent.rc has the "socket netdagent stream 0660 root system" line commented
# out, so the service comes up without its socket and each dispatch dies. The
# library then logs the failure from 8 sites, all at ERROR level with the
# libPowerHal tag.
#
# Fix: nop the 8 bl __android_log_print calls. Every site falls through to code
# that sets w0 explicitly (wzr or -1), so dropping the call changes no register
# or control flow the caller can observe; the error returns themselves stay.
# The netdagent daemon's own lines (NetdagentIptables / NetdagentService) come
# from /vendor/bin/netdagent and are NOT touched here.
#
# The 8 sites (all in the netd block, .text 0x32F00..0x34200):
#
#   0x32FC8  shared tail: dispatchNetdagentCmd failed / is not ok
#   0x333C0  netd_set_priority_uid:            SetPriorityWithUID fail / sprintf fail
#   0x33428  netd_set_priority_uid:            packet Priority UID fail, no empty slot
#   0x33538  netd_clear_priority_uid:          ClearPriorityWithUID fail / sprintf fail
#   0x33EB4  sdk_netd_set_priority_by_uid:     SetPriorityWithUID fail / sprintf fail
#   0x33F98  sdk_netd_clear_priority_by_uid:   ClearPriorityWithUID fail / sprintf fail
#   0x340B8  sdk_netd_set_priority_by_linkinfo NetdAgentCmd fail / sprintf fail
#   0x341D8  sdk_netd_clear_priority_by_linkinfo NetdAgentCmd fail / sprintf fail

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$In,
    [string]$Out
)

$ErrorActionPreference = 'Stop'

if (-not $Out) { $Out = "$In.patched" }
if (-not (Test-Path -LiteralPath $In)) { throw "input not found: $In" }

# function getCPUFreq @ .text 0x2812C
#   cid < 0 or nClusterNum <= cid ............ 0x281C0
#   0x281C8 adrp x2, 0xa000 / 0x281CC add x2, x2, #0xf03   (fmt string)
#   0x281D0 adrp x3, 0x13000 / 0x281D4 add x3, x3, #0x93e  ("getCPUFreq")
#   0x281D8 mov w0, #0x6 (ERROR) ............. 0x528000C0
#   0x281E0 bl __android_log_print ........... 0x94005BCC
#   0x281E4 b 0x28210 (w19 = -1; return -1) .. 0x1400000B
$nop = [uint32]::Parse('D503201F', [Globalization.NumberStyles]::HexNumber)

# offset, expected stock value, patched value, description
$edits = @(
    @{ Off = 0x281D8; From = [uint32]::Parse('528000C0', [Globalization.NumberStyles]::HexNumber); To = $null;
       What = 'mov w0, #0x6 (ERROR level) - context check' }
    @{ Off = 0x281E0; From = [uint32]::Parse('94005BCC', [Globalization.NumberStyles]::HexNumber); To = $nop;
       What = 'nop the "[%s] error cid:%d, nClusterNum:%d" log call' }
    @{ Off = 0x281E4; From = [uint32]::Parse('1400000B', [Globalization.NumberStyles]::HexNumber); To = $null;
       What = 'b 0x28210 (return -1) - context check' }
)

$fmt = "[%s] error cid:%d, nClusterNum:%d"
$fmtOff = 0xAF03

# netdagent error paths: every bl __android_log_print in .text 0x32F00..0x34200
# that only prints a netd* failure. offset, expected stock bl word, description.
$netdNops = @(
    @{ Off = 0x32FC8; From = '94003052'; What = 'dispatchNetdagentCmd failed / is not ok' }
    @{ Off = 0x333C0; From = '94002F54'; What = 'netd_set_priority_uid: SetPriorityWithUID fail' }
    @{ Off = 0x33428; From = '94002F3A'; What = 'netd_set_priority_uid: no more empty slot' }
    @{ Off = 0x33538; From = '94002EF6'; What = 'netd_clear_priority_uid: ClearPriorityWithUID fail' }
    @{ Off = 0x33EB4; From = '94002C97'; What = 'sdk_netd_set_priority_by_uid: SetPriorityWithUID fail' }
    @{ Off = 0x33F98; From = '94002C5E'; What = 'sdk_netd_clear_priority_by_uid: ClearPriorityWithUID fail' }
    @{ Off = 0x340B8; From = '94002C16'; What = 'sdk_netd_set_priority_by_linkinfo: NetdAgentCmd fail' }
    @{ Off = 0x341D8; From = '94002BCE'; What = 'sdk_netd_clear_priority_by_linkinfo: NetdAgentCmd fail' }
)

# every netd* format literal the sites above can print, used as a build guard
# (start offsets include the leading "[%s] " prefix)
$netdMsgs = @(
    @{ Off = 0xC2FD; Text = '[%s] dispatchNetdagentCmd failed' }
    @{ Off = 0xEAE2; Text = '[%s] dispatchNetdagentCmd is not ok' }
    @{ Off = 0xE21A; Text = '[%s] SetPriorityWithUID fail' }
    @{ Off = 0x11EDF; Text = '[%s] sprintf fail' }
    @{ Off = 0xB51E; Text = '[%s] Set packet Priority UID(%d) fail: no more empty slot' }
    @{ Off = 0xC2DE; Text = '[%s] ClearPriorityWithUID fail' }
    @{ Off = 0x123F5; Text = '[%s] sdk_netd_set_priority_by_linkinfo NetdAgentCmd fail' }
    @{ Off = 0xE254; Text = '[%s] sdk_netd_set_priority_by_linkinfo sprintf fail' }
    @{ Off = 0xB558; Text = '[%s] sdk_netd_clear_priority_by_linkinfo NetdAgentCmd fail' }
    @{ Off = 0xF441; Text = '[%s] sdk_netd_clear_priority_by_linkinfo sprintf fail' }
)

# .rodata path literals (file offset == virtual address in this build).
# offset, expected stock string, replacement, description
$strEdits = @(
    @{ Off = 0x12287; From = '/proc/driver/thermal/ta_fg_pid'; To = '/dev/null';
       What = 'perfNotifyAppState thermal fg-pid node -> /dev/null' }
    @{ Off = 0x122A6; From = '/sys/module/ged/parameters/gx_top_app_pid'; To = '/dev/null';
       What = 'perfNotifyAppState GED top-app-pid node -> /dev/null' }
)

$bytes = [IO.File]::ReadAllBytes($In)
if ($bytes.Length -lt $fmtOff + $fmt.Length) { throw "input too small, not this library: $($bytes.Length) bytes" }

$onDisk = [Text.Encoding]::ASCII.GetString($bytes, $fmtOff, $fmt.Length)
if ($onDisk -ne $fmt) { throw "format string mismatch at 0x$('{0:X}' -f $fmtOff): '$onDisk' - wrong stock build?" }

foreach ($e in $strEdits) {
    $off = [int]$e.Off
    $len = $e.From.Length
    if ($bytes[$off + $len] -ne 0) { throw ("path at 0x{0:X} is not NUL-terminated as expected - wrong stock build?" -f $off) }
    $cur = [Text.Encoding]::ASCII.GetString($bytes, $off, $len)
    if ($cur -ne $e.From) { throw ("offset 0x{0:X} mismatch: expected '$($e.From)', got '$cur' - wrong stock build?" -f $off) }
    $repl = New-Object byte[] $len          # NUL-padded, so the old literal is fully overwritten
    $to = [Text.Encoding]::ASCII.GetBytes($e.To)
    if ($to.Length -gt $len) { throw ("replacement '$($e.To)' does not fit into $len bytes at 0x{0:X}" -f $off) }
    [Array]::Copy($to, 0, $repl, 0, $to.Length)
    [Array]::Copy($repl, 0, $bytes, $off, $len)
    Write-Host ("[*] 0x{0:X}  '{1}' -> '{2}'  {3}" -f $off, $cur, $e.To, $e.What)
}

foreach ($e in $edits) {
    $off = [int]$e.Off
    $cur = [BitConverter]::ToUInt32($bytes, $off)
    if ($cur -ne $e.From) {
        throw ("offset 0x{0:X} mismatch: expected 0x{1:X}, got 0x{2:X} - wrong stock build?" -f $off, $e.From, $cur)
    }
    if ($null -ne $e.To) {
        [BitConverter]::GetBytes([uint32]$e.To).CopyTo($bytes, $off)
    }
    Write-Host ("[*] 0x{0:X}  0x{1:X} -> {2}  {3}" -f $off, $e.From, $(if ($null -ne $e.To) { '0x{0:X}' -f $e.To } else { '(unchanged)' }), $e.What)
}

foreach ($m in $netdMsgs) {
    $off = [int]$m.Off
    $cur = [Text.Encoding]::ASCII.GetString($bytes, $off, $m.Text.Length)
    if ($cur -ne $m.Text) { throw ("netd msg at 0x{0:X} mismatch: expected '$($m.Text)', got '$cur' - wrong stock build?" -f $off) }
}
Write-Host ("[*] netd block guard OK ({0} literals)" -f $netdMsgs.Count)

foreach ($e in $netdNops) {
    $off = [int]$e.Off
    $want = [uint32]::Parse($e.From, [Globalization.NumberStyles]::HexNumber)
    $cur = [BitConverter]::ToUInt32($bytes, $off)
    if ($cur -ne $want) { throw ("offset 0x{0:X} mismatch: expected 0x{1:X}, got 0x{2:X} - wrong stock build?" -f $off, $want, $cur) }
    # decode bl imm26 and require the call target to be __android_log_print@plt (0x3F110)
    $imm = $cur -band 0x03FFFFFF
    if ($imm -band 0x02000000) { $imm -= 0x04000000 }
    $target = $off + 4 * $imm
    if ($target -ne 0x3F110) { throw ("offset 0x{0:X}: bl target 0x{1:X} is not __android_log_print@plt - wrong stock build?" -f $off, $target) }
    [BitConverter]::GetBytes([uint32]$nop).CopyTo($bytes, $off)
    Write-Host ("[*] 0x{0:X}  0x{1:X} -> nop  {2}" -f $off, $cur, $e.What)
}

[IO.File]::WriteAllBytes($Out, $bytes)

$md5 = (Get-FileHash -LiteralPath $Out -Algorithm MD5).Hash.ToLower()
$sha = (Get-FileHash -LiteralPath $Out -Algorithm SHA256).Hash.ToLower()
Write-Host ("[+] wrote {0} ({1} bytes)" -f $Out, $bytes.Length)
Write-Host "    md5    $md5"
Write-Host "    sha256 $sha"
