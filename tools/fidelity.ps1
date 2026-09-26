<#
.SYNOPSIS
  The compile-compare harness: dcc judges PasTree's tree through the .dcu.

.DESCRIPTION
  For every unit of a list file: compile the original, let PasTreeXform write
  a transformed copy, compile the copy with the same switches, and compare
  the two .dcu files byte for byte. A transformation that keeps the meaning
  FOR PASTREE'S TREE leaves the .dcu identical exactly when that tree agrees
  with dcc's - no expectation files, dcc is the judge.

  One line per unit (results.txt), then a summary (summary.txt):
    OK          the two .dcu are byte-identical
    DIFF        they differ; the routines whose code differs follow, read
                from `PasTreeDcu -dump` of both (raw bytes are the verdict,
                the dump only locates)
    XFORM-FAIL  the copy does not compile (a wrong span, usually)
    BASE-FAIL   the ORIGINAL does not compile standalone - skipped, counted.
                `copy incomplete` after it: dcc did not find a file that
                lies beside the original, so the copy lacks one it needs -
                one the preprocessor never read (an include in a branch it
                skipped and dcc did not, say)
    TOOL-FAIL   PasTreeXform refused the unit (its message follows)

  Mode ts is the selftest: every unit with a site must DIFF and the dump must
  name every site's routine; a unit without one must stay OK. The run fails
  otherwise - a comparator that cannot see a planted error proves nothing.

  Mode t0f judges the PREPROCESSOR: the copy is the unit as PasTree saw it
  (inactive regions and conditional directives blanked, see PasTreeXform).
  Its lines name the unit's guessed and unreadable $IF expressions, and the
  summary counts them per outcome: a guess in an OK unit went dcc's way.

  Rules the compiles follow (both sides alike):
  - dcc by FULL path (the one on PATH may be another version), -$O- (dead
    store elimination hides wrong trees) - but t0f takes dcc's defaults, the
    preprocessor's own starting state - and `-U<lib>` for the shipped units;
  - both sides compile a COPY in a directory of its own - the original as a
    plain File.Copy of every file the unit reads, the transformed one as
    PasTreeXform wrote it, mirrored the same way - run there with the bare
    file name. Never the original in place: a .dcu records the source file
    of every OTHER unit whose inline routines it expands (a drUnitInlineSrc
    record, tag $76) with that file's mtime - or 0 when dcc cannot find the
    source - so a compile that sees the sibling sources differs from one
    that does not (12 of this repository's 25 units, the first T0 run);
  - and both at the SAME path (see Compile-Side: Assert embeds it);
  - the header's file time is the compile's own moment and is masked (see
    Same-Dcu); every other byte counts;
  - every compile writes into its own -N0 directory;
  - -Base first compiles every listed unit into <Out>\base and puts it on
    the unit path: a corpus whose units use each other (this repository's
    own source\) then compiles each one standalone against the others'
    ORIGINAL .dcu files.

  -XformDefine / -XformUndefine reach PasTreeXform only, never dcc: a way to
  hand the preprocessor a corrected predefined set and see past a known
  define-set difference. -Jobs N runs N worker processes over slices of the
  list; the results are merged back in list order.

.EXAMPLE
  .\fidelity.ps1 -List units.txt -Mode t0 -Out C:\work\t0 -Base
#>
param(
  [Parameter(Mandatory = $true)] [string] $List,
  [Parameter(Mandatory = $true)] [ValidateSet('t0', 'ts', 't0f')] [string] $Mode,
  [Parameter(Mandatory = $true)] [string] $Out,
  [string] $Platform = 'Win64',
  [string] $Bds = 'C:\Program Files (x86)\Embarcadero\Studio\37.0',
  [string[]] $UnitPath = @(),
  [string[]] $IncludePath = @(),
  [string[]] $Define = @(),
  [string[]] $XformDefine = @(),
  [string[]] $XformUndefine = @(),
  [string] $Namespaces = 'System;System.Win;Winapi;Data;Xml',
  [string[]] $Switches = @('-$O-'),
  [string] $Tools = '',   # default: out64 beside this script
  [int] $Jobs = 1,
  [switch] $Base,
  # t0f: flatten the stream a PROJECT analysis makes wherever a $IF asked
  # the Declared/SizeOf oracle (PasTreeXform -oracle), its units found on
  # -OraclePath - the Studio source trees when none is given.
  [switch] $Oracle,
  [string[]] $OraclePath = @(),
  # Internal: set on a worker (see -Jobs) - the parent's parameters, as JSON;
  # -List is then the worker's slice.
  [string] $Worker = ''
)

$ErrorActionPreference = 'Stop'
# Not in the param default: $PSScriptRoot is empty there under -File.
if ($Tools -eq '') { $Tools = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'out64' }
# t0f compiles with dcc's OWN default switches unless told otherwise: they
# are the state the preprocessor starts from (probed on dcc64 37.0: the same
# but for N, which nothing tests), while a command-line switch is state it
# never sees - under -$O- System.Classes' `$IFOPT O+` went one way for dcc
# and the other for PasTree, and every routine after it differed.
if ($Mode -eq 't0f' -and -not $PSBoundParameters.ContainsKey('Switches') -and $Worker -eq '') {
  $Switches = @()
}

if ($Worker -ne '') {
  # Arrays do not survive a -File command line; everything but the slice
  # comes from the parent's own parameters instead.
  $p = Get-Content -LiteralPath $Worker -Raw | ConvertFrom-Json
  $strings = { param($v) @($v | Where-Object { $_ -ne $null -and "$_" -ne '' } | ForEach-Object { "$_" }) }
  $Platform = $p.Platform; $Bds = $p.Bds; $Namespaces = $p.Namespaces; $Tools = $p.Tools
  $UnitPath = & $strings $p.UnitPath; $IncludePath = & $strings $p.IncludePath
  $Define = & $strings $p.Define; $XformDefine = & $strings $p.XformDefine
  $XformUndefine = & $strings $p.XformUndefine; $Switches = & $strings $p.Switches
  $Base = [bool]$p.Base; $Oracle = [bool]$p.Oracle; $OraclePath = & $strings $p.OraclePath
}
if ($Oracle -and $OraclePath.Count -eq 0) {
  # What PasTreeSemaProject -proj adds (StudioSearchPaths there).
  $OraclePath = @('source\rtl\sys', 'source\rtl\common', 'source\rtl\win',
    'source\rtl\win\winrt', 'source\rtl\net', 'source\databinding\engine',
    'source\xml', 'source\vcl', 'source\fmx') | ForEach-Object { Join-Path $Bds $_ } |
    Where-Object { Test-Path -LiteralPath $_ }
}

$dcc = Join-Path $Bds ($(if ($Platform -eq 'Win32') { 'bin\dcc32.exe' } else { 'bin\dcc64.exe' }))
$lib = Join-Path $Bds ('lib\' + $Platform.ToLower() + '\release')
$xform = Join-Path $Tools 'PasTreeXform.exe'
$dcuTool = Join-Path $Tools 'PasTreeDcu.exe'
foreach ($f in @($dcc, $xform, $dcuTool)) {
  if (-not (Test-Path -LiteralPath $f)) { throw "not found: $f" }
}
if (-not (Test-Path -LiteralPath $lib)) { throw "not found: $lib" }

$Out = [IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Force -Path $Out | Out-Null

# Runs an exe in a working directory; stdout and stderr captured whole.
function Invoke-Tool([string] $Exe, [string[]] $ArgList, [string] $Cwd) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  $psi.Arguments = ($ArgList | ForEach-Object {
      if ($_ -match '[\s]') { '"' + $_ + '"' } else { $_ } }) -join ' '
  $psi.WorkingDirectory = $Cwd
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $errTask = $p.StandardError.ReadToEndAsync()
  $stdout = $p.StandardOutput.ReadToEnd()
  $p.WaitForExit()
  [pscustomobject]@{ Exit = $p.ExitCode; Out = $stdout; Err = $errTask.Result }
}

# One dcc compile of AFile (a bare name inside ADir) into ADcuDir.
function Invoke-Dcc([string] $Dir, [string] $File, [string] $DcuDir,
                    [string[]] $UnitDirs, [string[]] $IncDirs) {
  New-Item -ItemType Directory -Force -Path $DcuDir | Out-Null
  # -O: the object files a `$L` links ship beside the .dcu files, and dcc
  # looks for them on the object path, not the unit path.
  $a = @('-Q') + $Switches + @("-NS$Namespaces",
    ('-U' + (($UnitDirs + @($lib)) -join ';')), "-O$lib", "-N0$DcuDir")
  if ($IncDirs.Count -gt 0) { $a += ('-I' + ($IncDirs -join ';')) }
  if ($Define.Count -gt 0) { $a += ('-D' + ($Define -join ';')) }
  $a += $File
  Invoke-Tool $dcc $a $Dir
}

# The first error dcc printed - `file(line) Error: E2003 ...` - or its tail.
function First-Error([string] $Text) {
  $m = [regex]::Match($Text, '(?m)^.*\b(Error|Fatal): .*$')
  if ($m.Success) { return $m.Value.Trim() }
  $lines = $Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' }
  if ($lines) { return ($lines | Select-Object -Last 1).Trim() }
  return '(no output)'
}

# t0f: the .dcu records every inclusion under its name as written - a source
# record: tag $70, a length byte, the name, the file time - so an instance
# copy read as `inc\~2\x.inc` differs from the original by that name alone,
# and the header's size field (offset 4) by its length. $Map (copy spelling
# -> original spelling) maps them back; nothing else in the file names an
# include.
function Unmap-Names([byte[]] $Bytes, $Map) {
  $buf = New-Object System.Collections.Generic.List[byte]
  $buf.AddRange($Bytes)
  foreach ($k in $Map.Keys) {
    $kb = [Text.Encoding]::UTF8.GetBytes($k)
    $vb = [Text.Encoding]::UTF8.GetBytes($Map[$k])
    $pat = [byte[]](@(0x70, $kb.Length) + $kb)
    $rep = [byte[]](@(0x70, $vb.Length) + $vb)
    $i = 16
    while ($i -le $buf.Count - $pat.Length) {
      $hit = $true
      for ($j = 0; $j -lt $pat.Length; $j++) {
        if ($buf[$i + $j] -ne $pat[$j]) { $hit = $false; break }
      }
      if ($hit) {
        $buf.RemoveRange($i, $pat.Length)
        $buf.InsertRange($i, $rep)
        $i += $rep.Length
      } else { $i++ }
    }
  }
  $out = $buf.ToArray()
  [BitConverter]::GetBytes([uint32]$out.Length).CopyTo($out, 4)
  return ,$out
}

# Byte equality of two .dcu files but for the header's file time (offset 8,
# four bytes, DOS format): it is the moment of the COMPILE, so two compiles in
# different 2-second windows differ there and nowhere else. $Map: see
# Unmap-Names, applied to B.
function Same-Dcu([string] $A, [string] $B, $Map = $null) {
  $x = [IO.File]::ReadAllBytes($A)
  $y = [IO.File]::ReadAllBytes($B)
  if ($Map -and $Map.Count -gt 0) { $y = Unmap-Names $y $Map }
  if ($x.Length -ne $y.Length) { return $false }
  for ($i = 8; $i -lt 12 -and $i -lt $x.Length; $i++) { $x[$i] = 0; $y[$i] = 0 }
  $h = [Security.Cryptography.SHA256]::Create()
  return [BitConverter]::ToString($h.ComputeHash($x)) -eq [BitConverter]::ToString($h.ComputeHash($y))
}

# Compiles one side's tree AT THE SAME PATH as the other side's: the side's
# directory is renamed to <work>\cc for the compile and back afterwards. An
# Assert embeds the FULL path of its source file, so the same text compiled
# under `orig` and under `xf` differs by the two names' length.
function Compile-Side([string] $SideRoot, [string] $Work, [string] $Main,
                      [string] $XfRoot, [string[]] $IncDirs, [string] $DcuDir) {
  $cc = Join-Path $Work 'cc'
  $toCc = { param($p) $cc + $p.Substring($XfRoot.Length) }
  $ccMain = & $toCc $Main
  $ccInc = @($IncDirs | ForEach-Object { & $toCc $_ })
  [IO.Directory]::Move($SideRoot, $cc)
  try {
    Invoke-Dcc (Split-Path $ccMain) (Split-Path $ccMain -Leaf) $DcuDir $unitDirs $ccInc
  } finally {
    [IO.Directory]::Move($cc, $SideRoot)
  }
}

# A dump's data-carrying declarations of the `--- decls` part, keyed by
# qualified name (an embedded routine under its parent: `TFoo.M.Inner`),
# kind and occurrence (overloads share a name); the value is the bytes. The
# data@ OFFSET is left out - one routine growing moves every later one.
function Read-Dump([string] $Path) {
  $map = [ordered]@{}
  $seen = @{}
  $stack = New-Object System.Collections.Generic.List[string]
  $inDecls = $false
  $re = [regex]'^(?<pre>(?:    (?:emb |arg |gen |item )?)*)(?<kind>\w+) ''(?<name>[^'']*)''(?<rest>.*)$'
  foreach ($line in [IO.File]::ReadLines($Path)) {
    if ($line -eq '--- decls') { $inDecls = $true; continue }
    if ($line.StartsWith('--- fixups')) { break }
    if (-not $inDecls) { continue }
    $m = $re.Match($line)
    if (-not $m.Success) { continue }
    $depth = ([regex]::Matches($m.Groups['pre'].Value, '    ')).Count
    while ($stack.Count -gt $depth) { $stack.RemoveAt($stack.Count - 1) }
    $name = $m.Groups['name'].Value
    $qual = if ($depth -gt 0 -and $stack.Count -gt 0) { $stack[$stack.Count - 1] + '.' + $name } else { $name }
    $stack.Add($qual)
    $d = [regex]::Match($m.Groups['rest'].Value, 'data@[0-9A-F]+\[(\d+)\]=(.*)$')
    if (-not $d.Success) { continue }
    $key0 = $m.Groups['kind'].Value + ' ' + $qual
    $n = 1 + [int]$seen[$key0]
    $seen[$key0] = $n
    $map["$key0#$n"] = $d.Groups[2].Value
  }
  return $map
}

# The declarations whose data differ, split into routines and the rest
# ($pdata$/$unwind$ tables follow their routine's size and are not listed).
function Compare-Dumps([string] $A, [string] $B) {
  $ma = Read-Dump $A
  $mb = Read-Dump $B
  $routines = New-Object System.Collections.Generic.List[string]
  $other = New-Object System.Collections.Generic.List[string]
  $keys = @($ma.Keys) + @($mb.Keys | Where-Object { -not $ma.Contains($_) })
  foreach ($k in $keys) {
    if ($ma.Contains($k) -and $mb.Contains($k) -and $ma[$k] -eq $mb[$k]) { continue }
    $kind, $rest = $k -split ' ', 2
    $name = $rest -replace '#\d+$', ''
    if ($kind -eq 'routine') {
      if (-not $routines.Contains($name)) { $routines.Add($name) }
    } elseif ($name -notmatch '^\$(pdata|unwind)\$') {
      $other.Add("$kind $name")
    }
  }
  [pscustomobject]@{ Routines = $routines; Other = $other }
}

# The .dcu spells an operator method the C++ way; the source spelling is the
# Delphi operator name. The same table as TPasDcuPrinter.OperatorName in
# source\PasTree.Dcu.Source.pas - keep the two in step.
$opNames = @{
  'op_Implicit' = 'Implicit'; 'op_Explicit' = 'Explicit'; 'op_UnaryNegation' = 'Negative'
  'op_UnaryPlus' = 'Positive'; 'op_Increment' = 'Inc'; 'op_Decrement' = 'Dec'
  'op_LogicalNot' = 'LogicalNot'; 'op_Trunc' = 'Trunc'; 'op_Round' = 'Round'; 'op_In' = 'In'
  'op_Equality' = 'Equal'; 'op_Inequality' = 'NotEqual'; 'op_GreaterThan' = 'GreaterThan'
  'op_GreaterThanOrEqual' = 'GreaterThanOrEqual'; 'op_LessThan' = 'LessThan'
  'op_LessThanOrEqual' = 'LessThanOrEqual'; 'op_Addition' = 'Add'; 'op_Subtraction' = 'Subtract'
  'op_Multiply' = 'Multiply'; 'op_Division' = 'Divide'; 'op_IntDivide' = 'IntDivide'
  'op_Modulus' = 'Modulus'; 'op_LeftShift' = 'LeftShift'; 'op_RightShift' = 'RightShift'
  'op_LogicalAnd' = 'LogicalAnd'; 'op_LogicalOr' = 'LogicalOr'; 'op_LogicalXor' = 'LogicalXor'
  'op_BitwiseAnd' = 'BitwiseAnd'; 'op_BitwiseOr' = 'BitwiseOr'; 'op_ExclusiveOr' = 'BitwiseXor'
  'op_Initialize' = 'Initialize'; 'op_Finalize' = 'Finalize'; 'op_Assign' = 'Assign'
}

# Site routine vs dump routine, both reduced to the source spelling: no
# generic parameter lists (`TFoo<T>`) or arity marks (`TFoo`1`), no unit
# prefix of an instantiation (`{Unit}TFoo<System.Integer>.Get`), operators
# by their Delphi name, and no anonymous-method frame: the reader hangs a
# routine's nested routines under an anonymous-method body that precedes it
# in the file (`TFoo.M$ActRec.$0$Body.Inner` is TFoo.M's Inner - plan
# section 11), and the body itself belongs to the routine it is written in.
function Norm-Name([string] $Name) {
  $n = $Name -replace '^\{[^}]*\}', ''
  while ($n -match '<[^<>]*>') { $n = $n -replace '<[^<>]*>', '' }
  $n = $n -replace '`\d+', ''
  $n = $n -replace '\$ActRec\.\$\d+\$Body', ''
  $n = [regex]::Replace($n, '&?(op_\w+)$', {
      param($m) if ($opNames.ContainsKey($m.Groups[1].Value)) { $opNames[$m.Groups[1].Value] } else { $m.Value } })
  return $n.ToLower()
}

function Read-Sites([string] $Path) {
  $sites = @()
  foreach ($line in [IO.File]::ReadAllLines($Path)) {
    if ($line.StartsWith('#') -or $line.Trim() -eq '') { continue }
    $f = $line -split "`t"
    $sites += [pscustomobject]@{ Id = $f[0]; Kind = $f[1]; Ops = $f[2]; Span = $f[3]; Routine = $f[4] }
  }
  return ,$sites
}

# Invoke-Unit, with a failure of the harness itself reported as that unit's
# TOOL-FAIL rather than ending the run (or a worker's whole slice).
function Invoke-UnitSafe([string] $u, [string] $work) {
  try {
    return Invoke-Unit $u $work
  } catch {
    return [pscustomobject]@{ Outcome = 'TOOL-FAIL'
      Line = "TOOL-FAIL  $(Split-Path $u -Leaf)  harness: $($_.Exception.Message)"
      WithSites = 0; Diff = 0; Sites = 0; Named = 0; Broken = 1; Guessed = 0
      Unreadable = 0; CopyIncomplete = 0; ProjectStream = 0 }
  }
}

# One unit through the whole harness: the outcome line plus the counts the
# summary adds up (selftest bookkeeping for ts, the $IF guesses for t0f).
function Invoke-Unit([string] $u, [string] $work) {
  $r = [ordered]@{ Outcome = ''; Line = ''; WithSites = 0; Diff = 0; Sites = 0
    Named = 0; Broken = 0; Guessed = 0; Unreadable = 0; CopyIncomplete = 0; ProjectStream = 0 }
  $leaf = Split-Path $u -Leaf
  $stem = [IO.Path]::GetFileNameWithoutExtension($u)
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $dcuName = $stem + '.dcu'

  if ($baseFail.ContainsKey($u)) {
    $r.Outcome = 'BASE-FAIL'; $r.Line = "BASE-FAIL  $leaf  $($baseFail[$u])"
    return [pscustomobject]$r
  }

  # The transformation first: it also names every file the unit reads.
  $xfRoot = Join-Path $work 'xf'
  $origRoot = Join-Path $work 'orig'
  $xa = @($u, "-mode:$Mode", "-out:$xfRoot", "-p:$Platform")
  $xd = @($Define) + @($XformDefine)
  if ($xd.Count -gt 0) { $xa += ('-D:' + ($xd -join ';')) }
  if ($XformUndefine.Count -gt 0) { $xa += ('-Undef:' + ($XformUndefine -join ';')) }
  if ($IncludePath.Count -gt 0) { $xa += ('-I:' + ($IncludePath -join ';')) }
  if ($Oracle) { $xa += @('-oracle', ('-S:' + ($OraclePath -join ';'))) }
  $x = Invoke-Tool $xform $xa (Split-Path $u)
  Set-Content -LiteralPath (Join-Path $work 'xform.log') -Value ($x.Out + $x.Err)
  if ($x.Exit -ne 0) {
    $msg = (($x.Err -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 1)
    $r.Outcome = 'TOOL-FAIL'; $r.Line = "TOOL-FAIL  $leaf  $msg"
    return [pscustomobject]$r
  }
  $main = ([regex]::Match($x.Out, '(?m)^main (.+?)\s*$')).Groups[1].Value
  $xinc = @()
  foreach ($m in [regex]::Matches($x.Out, '(?m)^idir [^\t]*\t(.+?)\s*$')) { $xinc += $m.Groups[1].Value }
  $argMap = @{}
  foreach ($m in [regex]::Matches($x.Out, '(?m)^argmap ([^\t]+)\t(.+?)\s*$')) { $argMap[$m.Groups[1].Value] = $m.Groups[2].Value }
  $sites = Read-Sites (Join-Path $xfRoot 'sites.txt')
  $note = ''
  if ($Mode -eq 't0f') {
    $r.Guessed = @($sites | Where-Object { $_.Kind -eq 'if-guessed' }).Count
    $r.Unreadable = @($sites | Where-Object { $_.Kind -eq 'if-unreadable' }).Count
    $other = @($sites | Where-Object { $_.Kind -ne 'if-guessed' -and $_.Kind -ne 'if-unreadable' })
    $parts = @()
    if ($r.Guessed -gt 0) { $parts += "guessed $($r.Guessed)" }
    if ($r.Unreadable -gt 0) { $parts += "unreadable $($r.Unreadable)" }
    if ($other.Count -gt 0) { $parts += 'pp: ' + (($other | ForEach-Object { $_.Kind }) -join ',') }
    $copies = ([regex]::Matches($x.Out, '(?m)^copy ')).Count
    if ($copies -gt 0) { $parts += "instance copies $copies (names mapped back)" }
    if ($x.Out -match '(?m)^flatten .*stream=project') { $parts += 'project stream'; $r.ProjectStream = 1 }
    if ($parts.Count -gt 0) { $note = '  [' + ($parts -join '; ') + ']' }
  }

  # The original side: the same files as a plain copy, mirrored the same way,
  # the exact mtime set again (File.Copy keeps it; this makes it explicit).
  $toOrig = { param($p) $origRoot + $p.Substring($xfRoot.Length) }
  foreach ($m in [regex]::Matches($x.Out, '(?m)^file ([^\t]+)\t(.+?)\s*$')) {
    $from = $m.Groups[1].Value
    $to = & $toOrig $m.Groups[2].Value
    New-Item -ItemType Directory -Force -Path (Split-Path $to) | Out-Null
    [IO.File]::Copy($from, $to, $true)
    # A read-only source (an installed library) stays read-only as a copy,
    # and a read-only file takes no new time; PasTreeXform's copies are
    # plain files anyway.
    [IO.File]::SetAttributes($to, [IO.FileAttributes]::Normal)
    [IO.File]::SetLastWriteTimeUtc($to, [IO.File]::GetLastWriteTimeUtc($from))
  }
  $orig = Compile-Side $origRoot $work $main $xfRoot $xinc (Join-Path $work 'orig.dcu')
  Set-Content -LiteralPath (Join-Path $work 'orig.log') -Value $orig.Out
  if ($orig.Exit -ne 0) {
    $err = First-Error $orig.Out
    $r.Outcome = 'BASE-FAIL'
    $r.Line = "BASE-FAIL  $leaf  $err$note"
    # A file the copy lacks although it lies beside the original: one the
    # preprocessor never read.
    $nf = [regex]::Match($err, "File not found: '([^']+)'")
    if ($nf.Success) {
      $dirs = @(Split-Path $u) + @($IncludePath)
      if ($dirs | Where-Object { Test-Path -LiteralPath (Join-Path $_ $nf.Groups[1].Value) }) {
        $r.CopyIncomplete = 1
        $r.Line = "BASE-FAIL  $leaf  copy incomplete: $err$note"
      }
    }
    return [pscustomobject]$r
  }

  $xc = Compile-Side $xfRoot $work $main $xfRoot $xinc (Join-Path $work 'xf.dcu')
  Set-Content -LiteralPath (Join-Path $work 'xf.log') -Value $xc.Out
  if ($xc.Exit -ne 0) {
    $r.Outcome = 'XFORM-FAIL'; $r.Line = "XFORM-FAIL  $leaf  $(First-Error $xc.Out)$note"
    if ($Mode -eq 'ts') {
      # A planted regrouping must still compile; an unedited copy all the more.
      $r.Broken = 1
      if ($sites.Count -gt 0) { $r.WithSites = 1; $r.Sites = $sites.Count }
    }
    return [pscustomobject]$r
  }

  $a = Join-Path $work "orig.dcu\$dcuName"
  $b = Join-Path $work "xf.dcu\$dcuName"
  if (Same-Dcu $a $b $argMap) {
    $r.Outcome = 'OK'; $r.Line = "OK  $leaf$note"
    if ($Mode -eq 'ts' -and $sites.Count -gt 0) {
      # A planted error the comparator did not see.
      $r.WithSites = 1; $r.Sites = $sites.Count; $r.Broken = 1
      $r.Line = "OK  $leaf  SELFTEST-MISS: $($sites.Count) site(s), .dcu identical"
    }
    return [pscustomobject]$r
  }

  $r.Outcome = 'DIFF'
  foreach ($side in @(@($a, 'orig.dump'), @($b, 'xf.dump'))) {
    $d = Invoke-Tool $dcuTool @($side[0], '-dump') $work
    [IO.File]::WriteAllText((Join-Path $work $side[1]), $d.Out)
  }
  $cmp = Compare-Dumps (Join-Path $work 'orig.dump') (Join-Path $work 'xf.dump')
  # A switch or a declaration moved by the change can touch every routine:
  # the first few name it, the count says how far it reached.
  $cap = { param($l) if ($l.Count -le 6) { $l -join ', ' } else {
      (@($l)[0..5] -join ', ') + " ... ($($l.Count) in all)" } }
  $what = if ($cmp.Routines.Count -gt 0) { & $cap $cmp.Routines } else { '<no routine>' }
  if ($cmp.Other.Count -gt 0) { $what += "  +data: " + (& $cap $cmp.Other) }
  if ($cmp.Routines.Count -eq 0 -and $cmp.Other.Count -eq 0) { $what = '<no dump difference - raw bytes only>' }
  $r.Line = "DIFF  $leaf  $what$note"
  if ($Mode -eq 'ts') {
    $named = 0
    $miss = @()
    $diffNames = @($cmp.Routines | ForEach-Object { Norm-Name $_ })
    $siteNames = @($sites | ForEach-Object { Norm-Name $_.Routine })
    foreach ($s in $sites) {
      if ($diffNames -contains (Norm-Name $s.Routine)) { $named++ } else { $miss += $s.Routine }
    }
    # Differing routines no site explains - an inlined caller, say. Shown,
    # not failed: the selftest asks whether the planted errors are SEEN.
    $extra = @($cmp.Routines | Where-Object { $siteNames -notcontains (Norm-Name $_) })
    if ($sites.Count -gt 0) {
      $r.WithSites = 1; $r.Diff = 1; $r.Sites = $sites.Count; $r.Named = $named
      if ($named -lt $sites.Count) { $r.Broken = 1 }
    } else {
      $r.Broken = 1   # a DIFF with no edit at all: the copy is not a copy
    }
    $line = "DIFF  $leaf  sites $named/$($sites.Count) named"
    if ($miss.Count -gt 0) { $line += "  NOT NAMED: " + ($miss -join ', ') }
    if ($extra.Count -gt 0) { $line += "  extra: " + ($extra -join ', ') }
    if ($cmp.Other.Count -gt 0) { $line += "  +data: " + ($cmp.Other -join ', ') }
    $r.Line = $line
  }
  return [pscustomobject]$r
}

$started = Get-Date
$baseFail = @{}

if ($Worker -ne '') {
  # A worker: its slice, `index<TAB>unit<TAB>work dir` per line; one JSON
  # result per line back, the index first.
  $unitDirs = @($UnitPath)
  if ($Base) { $unitDirs = @(Join-Path $Out 'base') + $unitDirs }
  $bf = Join-Path $Out 'base-fail.json'
  if (Test-Path -LiteralPath $bf) {
    (Get-Content -LiteralPath $bf -Raw | ConvertFrom-Json).PSObject.Properties |
      ForEach-Object { $baseFail[$_.Name] = $_.Value }
  }
  $res = New-Object System.Collections.Generic.List[string]
  foreach ($line in [IO.File]::ReadAllLines($List)) {
    if ($line.Trim() -eq '') { continue }
    $idx, $u, $work = $line -split "`t"
    $o = Invoke-UnitSafe $u $work
    $o | Add-Member -NotePropertyName Index -NotePropertyValue ([int]$idx)
    $res.Add(($o | ConvertTo-Json -Compress))
    # Progress for whoever watches a long run; the results come at the end.
    [IO.File]::AppendAllText($List + '.progress', $o.Line + "`r`n")
  }
  [IO.File]::WriteAllLines($List + '.out', $res)
  exit 0
}

$units = @(Get-Content -LiteralPath $List | Where-Object {
    $_.Trim() -ne '' -and -not $_.TrimStart().StartsWith('#') } |
  ForEach-Object { [IO.Path]::GetFullPath($_.Trim()) })

# Each unit's work directory, `u\<Unit>` - a second unit of the same name
# gets `~2` and so on.
$names = @{}
$works = @()
foreach ($u in $units) {
  $stem = [IO.Path]::GetFileNameWithoutExtension($u)
  $n = 1 + [int]$names[$stem.ToLower()]
  $names[$stem.ToLower()] = $n
  $works += (Join-Path $Out ('u\' + $stem + $(if ($n -gt 1) { "~$n" } else { '' })))
}

$unitDirs = @($UnitPath)
if ($Base) {
  $baseDir = Join-Path $Out 'base'
  $unitDirs = @($baseDir) + $unitDirs
  foreach ($u in $units) {
    $r = Invoke-Dcc (Split-Path $u) (Split-Path $u -Leaf) $baseDir $unitDirs $IncludePath
    if ($r.Exit -ne 0) { $baseFail[$u] = First-Error $r.Out }
  }
}

$outcomes = New-Object 'object[]' $units.Count
if ($Jobs -le 1) {
  for ($i = 0; $i -lt $units.Count; $i++) {
    $outcomes[$i] = Invoke-UnitSafe $units[$i] $works[$i]
    Write-Output $outcomes[$i].Line
  }
} else {
  $jobDir = Join-Path $Out 'jobs'
  if (Test-Path -LiteralPath $jobDir) { Remove-Item -LiteralPath $jobDir -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $jobDir | Out-Null
  $params = [ordered]@{ Platform = $Platform; Bds = $Bds; Namespaces = $Namespaces
    Tools = $Tools; UnitPath = @($UnitPath); IncludePath = @($IncludePath)
    Define = @($Define); XformDefine = @($XformDefine); XformUndefine = @($XformUndefine)
    Switches = @($Switches); Base = [bool]$Base; Oracle = [bool]$Oracle
    OraclePath = @($OraclePath) }
  $paramFile = Join-Path $jobDir 'params.json'
  [IO.File]::WriteAllText($paramFile, ($params | ConvertTo-Json))
  [IO.File]::WriteAllText((Join-Path $Out 'base-fail.json'), ($baseFail | ConvertTo-Json))
  # Round-robin slices: neighbours in a list tend to cost alike.
  $slices = @()
  for ($k = 0; $k -lt $Jobs; $k++) { $slices += ,(New-Object System.Collections.Generic.List[string]) }
  for ($i = 0; $i -lt $units.Count; $i++) {
    $slices[$i % $Jobs].Add("$i`t$($units[$i])`t$($works[$i])")
  }
  $procs = @()
  for ($k = 0; $k -lt $Jobs; $k++) {
    if ($slices[$k].Count -eq 0) { continue }
    $sf = Join-Path $jobDir "slice$k.txt"
    [IO.File]::WriteAllLines($sf, $slices[$k])
    $wa = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
      '-List', "`"$sf`"", '-Mode', $Mode, '-Out', "`"$Out`"", '-Worker', "`"$paramFile`"")
    $procs += Start-Process -FilePath 'powershell.exe' -ArgumentList $wa -PassThru -WindowStyle Hidden `
      -RedirectStandardError (Join-Path $jobDir "slice$k.err") -RedirectStandardOutput (Join-Path $jobDir "slice$k.log")
  }
  $procs | ForEach-Object { $_.WaitForExit() }
  for ($k = 0; $k -lt $Jobs; $k++) {
    $rf = Join-Path $jobDir "slice$k.txt.out"
    if ($slices[$k].Count -eq 0) { continue }
    if (-not (Test-Path -LiteralPath $rf)) {
      throw "worker $k left no results - see $(Join-Path $jobDir "slice$k.err")"
    }
    foreach ($line in [IO.File]::ReadAllLines($rf)) {
      $o = $line | ConvertFrom-Json
      $outcomes[$o.Index] = $o
    }
  }
  for ($i = 0; $i -lt $units.Count; $i++) {
    if ($null -eq $outcomes[$i]) { throw "no result for $($units[$i])" }
    Write-Output $outcomes[$i].Line
  }
}

$results = New-Object System.Collections.Generic.List[string]
$counts = [ordered]@{ 'OK' = 0; 'DIFF' = 0; 'XFORM-FAIL' = 0; 'BASE-FAIL' = 0; 'TOOL-FAIL' = 0 }
$selftest = [ordered]@{ UnitsWithSites = 0; UnitsDiff = 0; Sites = 0; Named = 0; Broken = 0 }
$guess = [ordered]@{}
foreach ($k in $counts.Keys) { $guess[$k] = @(0, 0) }
$copyIncomplete = 0
$projectStream = 0
$unreadable = 0
foreach ($o in $outcomes) {
  $results.Add($o.Line)
  $counts[$o.Outcome]++
  $selftest.UnitsWithSites += $o.WithSites; $selftest.UnitsDiff += $o.Diff
  $selftest.Sites += $o.Sites; $selftest.Named += $o.Named; $selftest.Broken += $o.Broken
  if ($o.Guessed -gt 0) { $guess[$o.Outcome] = @(($guess[$o.Outcome][0] + 1), ($guess[$o.Outcome][1] + $o.Guessed)) }
  $copyIncomplete += $o.CopyIncomplete
  $projectStream += $o.ProjectStream
  $unreadable += $o.Unreadable
}

$elapsed = ((Get-Date) - $started).TotalSeconds
$summary = New-Object System.Collections.Generic.List[string]
$summary.Add(("mode={0} platform={1} units={2} {3}  ({4:N0} s)" -f $Mode, $Platform,
  $units.Count, (($counts.Keys | ForEach-Object { "$($_.ToLower())=$($counts[$_])" }) -join ' '), $elapsed))
if ($copyIncomplete -gt 0) { $summary.Add("base-fail with an incomplete copy: $copyIncomplete") }
if ($Oracle) { $summary.Add("units flattened from the project stream (-Oracle): $projectStream") }
$pass = $true
if ($Mode -eq 'ts') {
  $summary.Add(("selftest: units with sites={0} diff={1} sites={2} named={3} broken={4}" -f
    $selftest.UnitsWithSites, $selftest.UnitsDiff, $selftest.Sites, $selftest.Named, $selftest.Broken))
  $pass = ($selftest.Broken -eq 0) -and ($counts['TOOL-FAIL'] -eq 0) -and ($selftest.UnitsWithSites -gt 0)
} else {
  if ($Mode -eq 't0f') {
    $summary.Add(('guessed $IF, units (sites) per outcome: ' + (($guess.Keys | ForEach-Object {
        "$($_.ToLower())=$($guess[$_][0]) ($($guess[$_][1]))" }) -join ' ') + "; unreadable `$IF sites=$unreadable"))
  }
  # An incomplete copy is no skip: the unit needs a file the transformation
  # never read, which is a divergence of its own.
  $pass = ($counts['DIFF'] -eq 0) -and ($counts['XFORM-FAIL'] -eq 0) -and
    ($counts['TOOL-FAIL'] -eq 0) -and ($copyIncomplete -eq 0)
}
$summary.Add($(if ($pass) { 'PASS' } else { 'FAIL' }))
$summary | ForEach-Object { Write-Output $_ }
$results | Set-Content -LiteralPath (Join-Path $Out 'results.txt')
$summary | Set-Content -LiteralPath (Join-Path $Out 'summary.txt')
if (-not $pass) { exit 1 }
