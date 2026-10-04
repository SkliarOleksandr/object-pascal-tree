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
    NONDET      the .dcu differed, but dcc itself is not deterministic on
                this unit under these switches: the original compiled again
                gave another .dcu, or the copy compiled again gave the
                original's; counted, not judged
    TOOL-FAIL   PasTreeXform refused the unit (its message follows)

  Mode ts is the selftest: every unit with a site must DIFF and the dump must
  name every site's routine; a unit without one must stay OK. The run fails
  otherwise - a comparator that cannot see a planted error proves nothing.

  Mode t0f judges the PREPROCESSOR: the copy is the unit as PasTree saw it
  (inactive regions and conditional directives blanked, see PasTreeXform).
  Its lines name the unit's guessed and unreadable $IF expressions, and the
  summary counts them per outcome: a guess in an OK unit went dcc's way.

  Mode t1 judges the PARSER's expressions: every operator node parenthesized
  along PasTree's tree (see PasTreeXform). On a DIFF or XFORM-FAIL the
  LOCALIZER names the sites responsible: parentheses around a node dcc groups
  the same way change nothing, so a subset of the sites differs from the
  original exactly when it holds a wrong one - the id range is halved and
  both halves compiled (PasTreeXform -sites:), down to single sites, about
  2 log2(n) compiles per culprit, at most -LocalizeBudget per unit. The
  culprits go on the unit's line and into u\<Unit>\culprits.txt. -Localize
  runs the localizer on a ts selftest too: it must name every planted site.

  Mode t2 judges the parser's STATEMENTS the same way: every statement in a
  statement position wrapped in begin/end along PasTree's tree (see
  PasTreeXform) - an else, a case branch or a statement's end placed
  differently from dcc changes the code; the localizer as for t1.

  Mode t3 judges the tree's COMPLETENESS and the structural printer: the
  unit printed from its tree, in place of its own tokens (see PasTreeXform),
  compiled with dcc's default switches - a spelling the printer takes for
  another that dcc does not, or a fact the tree lost, changes the .dcu. Mode
  t3x adds t1's parentheses and t2's blocks over the print, under t2's
  switches: the plan's final gate. The localizer as for t1 over their sites.

  Mode tq judges the RESOLVER's bindings (plan S12-S13): every name PasTree
  bound written so that dcc can only read it as the declaration PasTree
  chose - a unit-level one as <Unit>.Name, a member of the method's own type
  as Self.Name (see PasTreeXform). It takes PasTree's project analysis of
  the unit over -OraclePath (the Studio source trees when none is given) and
  t2's switches; a name dcc binds elsewhere changes the code or stops the
  compile, and the localizer names it as for t1. UNBOUND on a line counts
  the names PasTree did not bind at all (listed in sites.txt). Mode tqs is
  its selftest, as ts is t1's: in each routine ONE name written with a WRONG
  qualifier dcc accepts - another used unit's variable or routine of that
  name - which must DIFF or stop the compile, and -Localize must name each
  such site alone; a unit with no candidate takes no site.

  Mode tm judges the resolver's MEMBERS (plan S15): every member after a
  dot, every default array property and every with-bound name written
  through a hard cast to the type PasTree says declares it (see
  PasTreeXform). The casts' types of other units are named by a preamble
  ahead of the unit's code, so the ORIGINAL side here is PasTreeXform's
  rewrite with no site (-sites:none), not a plain copy; MISMATCH counts the
  members PasTree's own typing contradicts (listed in sites.txt). Mode tqm
  runs tq and tm together; tms is tm's selftest, as tqs is tq's: in each
  routine one member cast to an ancestor declaring another member of that
  name.

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
  [Parameter(Mandatory = $true)] [ValidateSet('t0', 'ts', 't0f', 't1', 't2', 't3', 't3x', 'tq', 'tqs', 'tm', 'tqm', 'tms')] [string] $Mode,
  [Parameter(Mandatory = $true)] [string] $Out,
  [string] $Platform = 'Win64',
  [string] $Bds = 'C:\Program Files (x86)\Embarcadero\Studio\37.0',
  [string[]] $UnitPath = @(),
  [string[]] $IncludePath = @(),
  # where dcc looks for the object files a `$L` links, before the shipped
  # ones (a corpus's own .obj - the copies hold only what the unit reads)
  [string[]] $ObjectPath = @(),
  # runtime packages the compiles use (dcc -LU): a design-time unit finds
  # DesignIntf or ToolsAPI only inside designide.dcp
  [string[]] $Packages = @(),
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
  # The localizer (see the description): on by default for t1, asked for on
  # a ts selftest; -NoLocalize turns it off; the budget counts variant
  # compiles per unit.
  [switch] $Localize,
  [switch] $NoLocalize,
  [int] $LocalizeBudget = 64,
  # ts, t1, t2: apply only these sites (PasTreeXform -sites:, `1-40,57`) - for
  # probing one site of a unit by hand.
  [string] $Sites = '',
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
# The resolver's modes (tq: unit-level names and Self; tm: members after a
# dot, default properties, with targets; tqm both; tqs and tms their
# selftests), and those that write tm's preamble into the original too.
$qModes = @('tq', 'tqs', 'tm', 'tqm', 'tms')
$memberModes = @('tm', 'tqm', 'tms')
if ($Mode -eq 't0f' -and -not $PSBoundParameters.ContainsKey('Switches') -and $Worker -eq '') {
  $Switches = @()
}
# t1 and t2 compile without line tables: the code-lines record ($90) gives
# code emitted after a lookahead the line of the LOOKAHEAD token - in
# `if C then A := A + [X]` / `else` on the next line, part of the
# concatenation's code sits on the `else` line, and with the parentheses on
# its own - so a `)` or an `end` that changes the token after an expression
# changes the table while the code stays byte-identical (probed on dcc64
# 37.0: -$D- -$L- together remove the difference, either alone does not).
# The code is the verdict; no Studio unit tests $IFOPT D or L.
# t2 also compiles without symbol reference info: the `$93` record keeps the
# line of a reference, and the same lookahead rule applies - with
# `if C then`, `inherited` and `else` on three lines the call's reference is
# recorded on the `else` line, with `begin inherited end` on its own; -$D-
# and -$L- leave that record in place, -$Y- removes it (probed on a VCL
# unit, dcc64 37.0; no Studio unit tests $IFOPT Y).
# tq qualifies names (Self.X, a hard cast to a member's type): under dcc's
# defaults the `$93` symbol-reference record differs, and -$Y- alone leaves
# the casts' lines (plan S12, probes Q04, Q05, Q12) - t2's set.
if ($Mode -in (@('t1', 't2', 't3x') + $qModes) -and -not $PSBoundParameters.ContainsKey('Switches') -and $Worker -eq '') {
  $Switches = @('-$O-', '-$D-', '-$L-')
  if ($Mode -in (@('t2', 't3x') + $qModes)) { $Switches += '-$Y-' }
}
# t3 - the print in place, every token on its line, nothing added - takes
# dcc's own defaults like t0f: line tables and symbol info on, the strictest
# judge of a print that must change nothing but spellings (dcc keeps lines,
# not columns: probe s10\probes\col). t3x adds t1's and t2's edits and their
# switches.
if ($Mode -eq 't3' -and -not $PSBoundParameters.ContainsKey('Switches') -and $Worker -eq '') {
  $Switches = @()
}

if ($Worker -ne '') {
  # Arrays do not survive a -File command line; everything but the slice
  # comes from the parent's own parameters instead.
  $p = Get-Content -LiteralPath $Worker -Raw | ConvertFrom-Json
  $strings = { param($v) @($v | Where-Object { $_ -ne $null -and "$_" -ne '' } | ForEach-Object { "$_" }) }
  $Platform = $p.Platform; $Bds = $p.Bds; $Namespaces = $p.Namespaces; $Tools = $p.Tools
  $UnitPath = & $strings $p.UnitPath; $IncludePath = & $strings $p.IncludePath
  $ObjectPath = & $strings $p.ObjectPath; $Packages = & $strings $p.Packages
  $Define = & $strings $p.Define; $XformDefine = & $strings $p.XformDefine
  $XformUndefine = & $strings $p.XformUndefine; $Switches = & $strings $p.Switches
  $Base = [bool]$p.Base; $Oracle = [bool]$p.Oracle; $OraclePath = & $strings $p.OraclePath
  $Localize = [bool]$p.Localize; $NoLocalize = [bool]$p.NoLocalize; $LocalizeBudget = [int]$p.LocalizeBudget
  $Sites = "$($p.Sites)"
}
# ts, tqs and tms are selftests: every planted site is wrong by construction.
$selfMode = $Mode -in @('ts', 'tqs', 'tms')
$doLocalize = (-not $NoLocalize) -and ($Mode -in @('t1', 't2', 't3', 't3x', 'tq', 'tm', 'tqm') -or ($selfMode -and $Localize))
if (($Oracle -or $Mode -in $qModes) -and $OraclePath.Count -eq 0) {
  # What PasTreeSemaProject -proj adds (StudioSearchPaths there), and
  # source\data: without it Data.DB stays unresolved, and so does every
  # member a dataset descendant inherits (S16: a corpus's datasets bound
  # their own `Close` to System's).
  $OraclePath = @('source\rtl\sys', 'source\rtl\common', 'source\rtl\win',
    'source\rtl\win\winrt', 'source\rtl\net', 'source\databinding\engine',
    'source\data', 'source\xml', 'source\vcl', 'source\fmx') | ForEach-Object { Join-Path $Bds $_ } |
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
    ('-U' + (($UnitDirs + @($lib)) -join ';')), ('-O' + ((@($ObjectPath) + @($lib)) -join ';')), "-N0$DcuDir")
  if ($IncDirs.Count -gt 0) { $a += ('-I' + ($IncDirs -join ';')) }
  if ($Define.Count -gt 0) { $a += ('-D' + ($Define -join ';')) }
  if (@($Packages).Count -gt 0) { $a += ('-LU' + ($Packages -join ';')) }
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
    # Every include directory exists in the copy, empty where no file of it
    # was read: dcc resolves `{$I ..\X.INC}` against each -I directory too,
    # `_avi\..\X.INC`, and skips one that does not exist (H2675) - 19 server
    # units found their include through a directory they read nothing from.
    foreach ($d in $ccInc) {
      if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
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
  # A call that only takes another target changes no byte of the routine,
  # only its fixup's slot (tms: `Strings.Remove` cast to an ancestor's
  # Remove): a differing fixup names the routine whose data holds it. The
  # fixups are compared routine by routine, at offsets relative to the
  # routine's data, so another routine's data growing elsewhere in the unit
  # does not hide it (S16: Vcl.Menus' TPopupMenu.Create beside a Destroy
  # whose data changed).
  $fa = Read-Fixups $A
  $fb = Read-Fixups $B
  $pa = Fixups-ByRoutine $fa
  $pb = Fixups-ByRoutine $fb
  foreach ($k in $pa.Keys) {
    if (-not $pb.Contains($k) -or $pa[$k] -eq $pb[$k]) { continue }
    $name = $k -replace '#\d+$', ''
    if (-not $routines.Contains($name)) { $routines.Add($name) }
  }
  [pscustomobject]@{ Routines = $routines; Other = $other }
}

# Read-Fixups' result as routine (name#n, the n-th of that name) -> its
# fixups at offsets relative to the routine's data, one string.
function Fixups-ByRoutine($F) {
  $by = [ordered]@{}
  $seen = @{}
  $offs = @($F.Fixups.Keys | ForEach-Object { [pscustomobject]@{ At = [Convert]::ToInt32($_, 16); Text = $F.Fixups[$_] } } |
    Sort-Object At)
  # Ranges in data order, swept once beside the sorted fixups.
  $i = 0
  foreach ($r in @($F.Ranges | Sort-Object Lo)) {
    $n = 0; if ($seen.ContainsKey($r.Name)) { $n = $seen[$r.Name] + 1 }
    $seen[$r.Name] = $n
    $sb = New-Object System.Text.StringBuilder
    while ($i -lt $offs.Count -and $offs[$i].At -lt $r.Lo) { $i++ }
    $j = $i
    while ($j -lt $offs.Count -and $offs[$j].At -lt $r.Hi) {
      [void]$sb.Append(('{0:X} {1};' -f ($offs[$j].At - $r.Lo), $offs[$j].Text))
      $j++
    }
    $by["$($r.Name)#$n"] = $sb.ToString()
  }
  return $by
}

# A dump's fixups, offset (hex) -> line, and the data range of each top-level
# routine, for Compare-Dumps.
function Read-Fixups([string] $Path) {
  $fix = [ordered]@{}
  $ranges = New-Object System.Collections.Generic.List[object]
  $inFix = $false
  $reR = [regex]'^routine ''(?<name>[^'']*)''.* data@(?<off>[0-9A-F]+)\[(?<len>\d+)\]='
  $reF = [regex]'^  @(?<off>[0-9A-F]+) (?<rest>.*)$'
  # A fixup names its target by declaration index: an import or a cast's
  # type added by the rewrite renumbers them all, so the index is read back
  # as the declaration's name (`'Name' #idx`, an import's `decl=#idx`); an
  # index the dump names nowhere (an anonymous record) reads as `?`, so a
  # renumbering does not name every routine (S16: Vcl.Grids, LongMulDiv).
  $reD = [regex]'''(?<name>[^'']*)'' #(?<idx>[0-9A-F]+)\b'
  $reI = [regex]'import ''(?<name>[^'']*)''.* decl=#(?<idx>[0-9A-F]+)\b'
  $reS = [regex]'slot=#(?<idx>[0-9A-F]+)'
  $decl = @{}
  foreach ($line in [IO.File]::ReadLines($Path)) {
    if ($line.StartsWith('--- fixups')) { $inFix = $true; continue }
    if (-not $inFix) {
      foreach ($re in @($reD, $reI)) {
        $d = $re.Match($line)
        if ($d.Success -and -not $decl.ContainsKey($d.Groups['idx'].Value)) { $decl[$d.Groups['idx'].Value] = $d.Groups['name'].Value }
      }
      $m = $reR.Match($line)
      if ($m.Success) {
        $lo = [Convert]::ToInt32($m.Groups['off'].Value, 16)
        $ranges.Add([pscustomobject]@{ Name = $m.Groups['name'].Value; Lo = $lo; Hi = $lo + [int]$m.Groups['len'].Value })
      }
      continue
    }
    $f = $reF.Match($line)
    if ($f.Success) {
      $fix[$f.Groups['off'].Value] = $reS.Replace($f.Groups['rest'].Value, {
          param($s) if ($decl.ContainsKey($s.Groups['idx'].Value)) { "slot='" + $decl[$s.Groups['idx'].Value] + "'" } else { 'slot=?' } })
    }
  }
  [pscustomobject]@{ Fixups = $fix; Ranges = $ranges }
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
# by their Delphi name, and no anonymous-method frame: the body belongs to
# the routine it is written in, and so does a routine nested in the body
# (`TFoo.M$ActRec.$0$Body.Inner` is written in TFoo.M). On Win32 the
# reader also still hangs a routine's own nested routines under such a body
# when the body's record precedes it (F5: only Win64 names the owner).
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
  # A list, not `+=`: a t1 unit has tens of thousands of sites.
  $sites = New-Object System.Collections.Generic.List[object]
  foreach ($line in [IO.File]::ReadAllLines($Path)) {
    if ($line.StartsWith('#') -or $line.Trim() -eq '') { continue }
    $f = $line -split "`t"
    $sites.Add([pscustomobject]@{ Id = $f[0]; Kind = $f[1]; Ops = $f[2]; Span = $f[3]; Routine = $f[4] })
  }
  return ,$sites.ToArray()
}

# PasTreeXform's arguments for unit $u written to $XfOut; $SiteList, when
# given, is its -sites: (the localizer's subsets).
function Xform-Args([string] $u, [string] $XfOut, [string] $SiteList = '') {
  $xa = @($u, "-mode:$Mode", "-out:$XfOut", "-p:$Platform")
  $xd = @($Define) + @($XformDefine)
  if ($xd.Count -gt 0) { $xa += ('-D:' + ($xd -join ';')) }
  if ($XformUndefine.Count -gt 0) { $xa += ('-Undef:' + ($XformUndefine -join ';')) }
  if ($IncludePath.Count -gt 0) { $xa += ('-I:' + ($IncludePath -join ';')) }
  if ($Oracle) { $xa += @('-oracle', ('-S:' + ($OraclePath -join ';')), "-NS:$Namespaces") }
  elseif ($Mode -in $qModes) { $xa += @(('-S:' + ($OraclePath -join ';')), "-NS:$Namespaces") }
  if ($SiteList -ne '') { $xa += "-sites:$SiteList" }
  elseif ($Sites -ne '') { $xa += "-sites:$Sites" }
  return ,$xa
}

# The localizer's probe: unit $u with only the sites $Lo..$Hi applied,
# compiled at the same path as both sides were; 'same' when its .dcu equals
# the original's, 'diff' when not, 'fail' when it does not compile, 'tool'
# when PasTreeXform refused.
function Test-Variant([string] $u, [string] $work, [int] $Lo, [int] $Hi,
                      [string] $OrigDcu, $ArgMap) {
  $vRoot = Join-Path $work 'xv'
  $vDcu = Join-Path $work 'xv.dcu'
  foreach ($d in @($vRoot, $vDcu)) {
    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
  }
  $x = Invoke-Tool $xform (Xform-Args $u $vRoot "$Lo-$Hi") (Split-Path $u)
  if ($x.Exit -ne 0) { return 'tool' }
  $vMain = ([regex]::Match($x.Out, '(?m)^main (.+?)\s*$')).Groups[1].Value
  $vInc = @()
  foreach ($m in [regex]::Matches($x.Out, '(?m)^idir [^\t]*\t(.+?)\s*$')) { $vInc += $m.Groups[1].Value }
  $c = Compile-Side $vRoot $work $vMain $vRoot $vInc $vDcu
  if ($c.Exit -ne 0) { return 'fail' }
  $leafDcu = [IO.Path]::GetFileNameWithoutExtension($u) + '.dcu'
  if (Same-Dcu $OrigDcu (Join-Path $vDcu $leafDcu) $ArgMap) { return 'same' }
  return 'diff'
}

# Every site of unit $u whose parentheses make the difference: the id range
# 1..$Count is known to differ ($Verdict, 'diff' or 'fail'); each range that
# differs is halved and both halves tried. A range whose halves each compile
# identically is a culprit only TOGETHER (reported as the range); a range the
# budget cut short is reported as unresolved. Returns the culprits in id
# order: Id (or Range), Verdict, and Compiles, the variant count spent.
function Find-Culprits([string] $u, [string] $work, [int] $Count, [string] $Verdict,
                       [string] $OrigDcu, $ArgMap) {
  $found = New-Object System.Collections.Generic.List[object]
  $todo = New-Object System.Collections.Generic.Stack[object]
  $todo.Push(@(1, $Count, $Verdict))
  $budget = $LocalizeBudget
  $spent = 0
  while ($todo.Count -gt 0) {
    $lo, $hi, $v = $todo.Pop()
    if ($lo -eq $hi) { $found.Add([pscustomobject]@{ Id = $lo; Range = "$lo"; Verdict = $v }); continue }
    if ($budget -lt 2) {
      $found.Add([pscustomobject]@{ Id = $lo; Range = "$lo-$hi"; Verdict = 'unresolved' }); continue
    }
    $mid = [int][Math]::Floor(($lo + $hi) / 2)
    $vl = Test-Variant $u $work $lo $mid $OrigDcu $ArgMap
    $vr = Test-Variant $u $work ($mid + 1) $hi $OrigDcu $ArgMap
    $budget -= 2; $spent += 2
    if ($vl -eq 'tool' -or $vr -eq 'tool') {
      $found.Add([pscustomobject]@{ Id = $lo; Range = "$lo-$hi"; Verdict = 'tool-fail' }); continue
    }
    if ($vl -eq 'same' -and $vr -eq 'same') {
      $found.Add([pscustomobject]@{ Id = $lo; Range = "$lo-$hi"; Verdict = "together-$v" }); continue
    }
    # Right first: the stack then hands the left half out first.
    if ($vr -ne 'same') { $todo.Push(@(($mid + 1), $hi, $vr)) }
    if ($vl -ne 'same') { $todo.Push(@($lo, $mid, $vl)) }
  }
  foreach ($d in @('xv', 'xv.dcu')) {
    $p = Join-Path $work $d
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
  }
  return [pscustomobject]@{ Culprits = @($found | Sort-Object Id); Compiles = $spent }
}

# The localizer's report: the culprits' site lines into culprits.txt, and a
# short form for the unit's line - the first three, then the count.
function Report-Culprits($Loc, $Sites, [string] $work) {
  $byId = @{}
  foreach ($s in $Sites) { $byId[[int]$s.Id] = $s }
  $lines = New-Object System.Collections.Generic.List[string]
  $short = New-Object System.Collections.Generic.List[string]
  foreach ($c in $Loc.Culprits) {
    if ($c.Range -eq "$($c.Id)" -and $byId.ContainsKey([int]$c.Id)) {
      $s = $byId[[int]$c.Id]
      $lines.Add("$($c.Id)`t$($c.Verdict)`t$($s.Kind)`t$($s.Ops)`t$($s.Span)`t$($s.Routine)")
      $short.Add("#$($c.Id) $($c.Verdict) $($s.Kind) '$($s.Ops)' $($s.Span)" +
        $(if ($s.Routine -ne '') { " [$($s.Routine)]" } else { '' }))
    } else {
      $lines.Add("$($c.Range)`t$($c.Verdict)")
      $short.Add("#$($c.Range) $($c.Verdict)")
    }
  }
  [IO.File]::WriteAllLines((Join-Path $work 'culprits.txt'), $lines)
  $text = (@($short)[0..([Math]::Min(2, $short.Count - 1))]) -join '; '
  if ($short.Count -gt 3) { $text += " ... ($($short.Count) in all)" }
  return "culprits ($($Loc.Compiles) compiles): $text"
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
      Unreadable = 0; CopyIncomplete = 0; ProjectStream = 0; AllSites = 0
      Excluded = 0; Dropped = 0; ParseDiags = 0; Culprits = 0; Localized = 0
      Compiles = 0 }
  }
}

# One unit through the whole harness: the outcome line plus the counts the
# summary adds up (selftest bookkeeping for ts, the $IF guesses for t0f).
function Invoke-Unit([string] $u, [string] $work) {
  $r = [ordered]@{ Outcome = ''; Line = ''; WithSites = 0; Diff = 0; Sites = 0
    Named = 0; Broken = 0; Guessed = 0; Unreadable = 0; CopyIncomplete = 0; ProjectStream = 0
    AllSites = 0; Excluded = 0; Dropped = 0; ParseDiags = 0; Culprits = 0; Localized = 0; Unbound = 0; Invisible = 0
    Mismatch = 0; Compiles = 0 }
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
  $x = Invoke-Tool $xform (Xform-Args $u $xfRoot) (Split-Path $u)
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
  if ($Mode -in (@('t1', 't2', 't3', 't3x') + $qModes)) {
    # The site counts: every operator (t1) or statement (t2) the tree holds,
    # the ones a rule leaves unwrapped (excluded-*) and the ones in no
    # single file; t3's are the print's changed spellings, one per node.
    $sl = [regex]::Match($x.Out, '(?m)^sites (\d+)(.*)$')
    $r.AllSites = [int]$sl.Groups[1].Value
    foreach ($m in [regex]::Matches($sl.Groups[2].Value, 'excluded-\w+ (\d+)')) {
      $r.Excluded += [int]$m.Groups[1].Value
    }
    $dr = [regex]::Match($sl.Groups[2].Value, 'dropped (\d+)')
    if ($dr.Success) { $r.Dropped = [int]$dr.Groups[1].Value }
    $pd = [regex]::Match($x.Out, '(?m)^parse (\d+)')
    if ($pd.Success) { $r.ParseDiags = [int]$pd.Groups[1].Value }
    if ($x.Out -match '(?m)^stream project') { $r.ProjectStream = 1 }
    $parts = @("sites $($r.AllSites)")
    foreach ($m in [regex]::Matches($sl.Groups[2].Value, '(excluded-\w+) (\d+)')) {
      $parts += "$($m.Groups[1].Value) $($m.Groups[2].Value)"
    }
    if ($r.Dropped -gt 0) { $parts += "dropped $($r.Dropped)" }
    $ub = [regex]::Match($sl.Groups[2].Value, 'unbound (\d+)')
    if ($ub.Success -and [int]$ub.Groups[1].Value -gt 0) {
      $r.Unbound = [int]$ub.Groups[1].Value; $parts += "UNBOUND $($r.Unbound)"
    }
    # tq: names bound to a unit no name there can come from - wrong whatever
    # dcc says (PasTreeXform lists them in sites.txt), not compiled.
    $iv = [regex]::Match($sl.Groups[2].Value, 'invisible (\d+)')
    if ($iv.Success -and [int]$iv.Groups[1].Value -gt 0) {
      $r.Invisible = [int]$iv.Groups[1].Value; $parts += "INVISIBLE $($r.Invisible)"
    }
    # tm: members whose binding PasTree's own typing of the base or the with
    # target contradicts (listed in sites.txt), not compiled.
    $mm = [regex]::Match($sl.Groups[2].Value, 'mismatch (\d+)')
    if ($mm.Success -and [int]$mm.Groups[1].Value -gt 0) {
      $r.Mismatch = [int]$mm.Groups[1].Value; $parts += "MISMATCH $($r.Mismatch)"
    }
    if ($r.ParseDiags -gt 0) { $parts += "PARSE DIAGNOSTICS $($r.ParseDiags)" }
    if ($r.ProjectStream -gt 0) { $parts += 'project stream' }
    $note = '  [' + ($parts -join '; ') + ']'
  }

  # The original side: the same files as a plain copy, mirrored the same way,
  # the exact mtime set again (File.Copy keeps it; this makes it explicit).
  # tm's is the rewrite with no site at all - its preamble alone, which the
  # rewrite and every localizer variant carry too (PasTreeXform -sites:none).
  $toOrig = { param($p) $origRoot + $p.Substring($xfRoot.Length) }
  if ($Mode -in $memberModes) {
    $xo = Invoke-Tool $xform (Xform-Args $u $origRoot 'none') (Split-Path $u)
    if ($xo.Exit -ne 0) {
      $msg = (($xo.Err -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 1)
      $r.Outcome = 'TOOL-FAIL'; $r.Line = "TOOL-FAIL  $leaf  original side: $msg"
      return [pscustomobject]$r
    }
  }
  foreach ($m in [regex]::Matches($x.Out, '(?m)^file ([^\t]+)\t(.+?)\s*$')) {
    if ($Mode -in $memberModes) { continue }
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
  $a = Join-Path $work "orig.dcu\$dcuName"
  $b = Join-Path $work "xf.dcu\$dcuName"
  if ($xc.Exit -ne 0) {
    $r.Outcome = 'XFORM-FAIL'; $r.Line = "XFORM-FAIL  $leaf  $(First-Error $xc.Out)$note"
    if ($Mode -eq 'ts') {
      # A planted regrouping must still compile; an unedited copy all the more.
      $r.Broken = 1
      if ($sites.Count -gt 0) { $r.WithSites = 1; $r.Sites = $sites.Count }
    }
    if ($Mode -in @('tqs', 'tms')) {
      # A planted wrong qualification may name a declaration of another
      # type: dcc refusing it SEES it. Every one must still be localized.
      if ($sites.Count -gt 0) {
        $r.WithSites = 1; $r.Diff = 1; $r.Sites = $sites.Count; $r.Named = $sites.Count
      } else {
        $r.Broken = 1
      }
    }
    if ($doLocalize -and $sites.Count -gt 0) {
      $loc = Find-Culprits $u $work $sites.Count 'fail' $a $argMap
      $r.Culprits = @($loc.Culprits).Count; $r.Compiles = $loc.Compiles
      if ($Mode -in @('tqs', 'tms')) {
        $ids = @($loc.Culprits | Where-Object { $_.Range -eq "$($_.Id)" } | ForEach-Object { [int]$_.Id })
        $r.Localized = @($sites | Where-Object { $ids -contains [int]$_.Id }).Count
        if ($r.Localized -lt $sites.Count) { $r.Broken = 1 }
      }
      $r.Line += '  ' + (Report-Culprits $loc $sites $work)
    }
    return [pscustomobject]$r
  }

  if (Same-Dcu $a $b $argMap) {
    $r.Outcome = 'OK'; $r.Line = "OK  $leaf$note"
    if ($selfMode -and $sites.Count -gt 0) {
      # A planted error the comparator did not see.
      $r.WithSites = 1; $r.Sites = $sites.Count; $r.Broken = 1
      $r.Line = "OK  $leaf  SELFTEST-MISS: $($sites.Count) site(s), .dcu identical"
    }
    return [pscustomobject]$r
  }

  # dcc is not always deterministic: under -$O- one Studio unit (Vcl.Skia)
  # compiles to a different .dcu from one run to the next, the text
  # unchanged (probed: five compiles, three results; with dcc's default
  # switches it is stable), and in another (Vcl.ControlList) one byte of a
  # class's method-resolution entry is garbage: the original takes a rare
  # value 3 times in 30 compiles, the copy with its blocks another mix (S6).
  # So before a difference is believed, both sides are compiled four times
  # more: a unit whose original compiles disagree among themselves, or whose
  # copy compiles even once to the original's .dcu, is NONDET - counted,
  # not judged. A variation that rare can still slip through as a DIFF with
  # no dump difference; such a DIFF is settled by compiling both sides many
  # times over (S6's repeat.ps1).
  for ($k = 2; $k -le 5; $k++) {
    $again = Compile-Side $origRoot $work $main $xfRoot $xinc (Join-Path $work "orig$k.dcu")
    if ($again.Exit -ne 0 -or -not (Same-Dcu $a (Join-Path $work "orig$k.dcu\$dcuName"))) {
      $r.Outcome = 'NONDET'
      $r.Line = "NONDET  $leaf  the original compiles to a different .dcu from run to run$note"
      return [pscustomobject]$r
    }
    $againX = Compile-Side $xfRoot $work $main $xfRoot $xinc (Join-Path $work "xf$k.dcu")
    if ($againX.Exit -eq 0 -and (Same-Dcu $a (Join-Path $work "xf$k.dcu\$dcuName") $argMap)) {
      $r.Outcome = 'NONDET'
      $r.Line = "NONDET  $leaf  the copy compiled once to the original's .dcu$note"
      return [pscustomobject]$r
    }
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
  if ($selfMode) {
    $named = 0
    $miss = @()
    $diffNames = @($cmp.Routines | ForEach-Object { Norm-Name $_ })
    $siteNames = @($sites | ForEach-Object { Norm-Name $_.Routine })
    foreach ($s in $sites) {
      # A site in no routine (tqs: a typed constant's value, a declaration)
      # is named by a difference outside every routine.
      if ($diffNames -contains (Norm-Name $s.Routine) -or
          ($s.Routine -eq '' -and $cmp.Other.Count -gt 0)) { $named++ } else { $miss += $s.Routine }
    }
    # Differing routines no site explains - an inlined caller, say. Shown,
    # not failed: the selftest asks whether the planted errors are SEEN.
    $extra = @($cmp.Routines | Where-Object { $siteNames -notcontains (Norm-Name $_) })
    if ($sites.Count -gt 0) {
      $r.WithSites = 1; $r.Diff = 1; $r.Sites = $sites.Count; $r.Named = $named
      # With the localizer on, it is the judge: a site it finds alone is
      # seen even when the dump cannot say where (a call taking another
      # import of the same name changes only an import record the dump does
      # not decode - plan F47; S16 tms FMX.Objects, Vcl.AppEvnts).
      if ($named -lt $sites.Count -and -not $doLocalize) { $r.Broken = 1 }
    } else {
      $r.Broken = 1   # a DIFF with no edit at all: the copy is not a copy
    }
    $line = "DIFF  $leaf  sites $named/$($sites.Count) named"
    if ($miss.Count -gt 0) { $line += "  NOT NAMED: " + ($miss -join ', ') }
    if ($extra.Count -gt 0) { $line += "  extra: " + ($extra -join ', ') }
    if ($cmp.Other.Count -gt 0) { $line += "  +data: " + ($cmp.Other -join ', ') }
    $r.Line = $line
  }
  if ($doLocalize -and $sites.Count -gt 0) {
    $loc = Find-Culprits $u $work $sites.Count 'diff' $a $argMap
    $r.Culprits = @($loc.Culprits).Count; $r.Compiles = $loc.Compiles
    if ($selfMode) {
      # Every planted site is wrong by construction: the localizer must find
      # each one ALONE, or it cannot be trusted with a real DIFF.
      $ids = @($loc.Culprits | Where-Object { $_.Range -eq "$($_.Id)" } | ForEach-Object { [int]$_.Id })
      $r.Localized = @($sites | Where-Object { $ids -contains [int]$_.Id }).Count
      if ($r.Localized -lt $sites.Count) { $r.Broken = 1 }
    }
    $r.Line += '  ' + (Report-Culprits $loc $sites $work)
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
    Tools = $Tools; UnitPath = @($UnitPath); IncludePath = @($IncludePath); ObjectPath = @($ObjectPath)
    Packages = @($Packages)
    Define = @($Define); XformDefine = @($XformDefine); XformUndefine = @($XformUndefine)
    Switches = @($Switches); Base = [bool]$Base; Oracle = [bool]$Oracle
    OraclePath = @($OraclePath); Localize = [bool]$Localize; NoLocalize = [bool]$NoLocalize
    LocalizeBudget = $LocalizeBudget; Sites = $Sites }
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
$counts = [ordered]@{ 'OK' = 0; 'DIFF' = 0; 'XFORM-FAIL' = 0; 'BASE-FAIL' = 0; 'NONDET' = 0; 'TOOL-FAIL' = 0 }
$selftest = [ordered]@{ UnitsWithSites = 0; UnitsDiff = 0; Sites = 0; Named = 0; Broken = 0 }
$guess = [ordered]@{}
foreach ($k in $counts.Keys) { $guess[$k] = @(0, 0) }
$copyIncomplete = 0
$projectStream = 0
$unreadable = 0
$t1 = [ordered]@{ Sites = 0; Excluded = 0; Dropped = 0; ParseUnits = 0; Culprits = 0; Compiles = 0; Unbound = 0; UnboundUnits = 0; Invisible = 0; InvisibleUnits = 0; Mismatch = 0; MismatchUnits = 0 }
$localized = 0
foreach ($o in $outcomes) {
  $results.Add($o.Line)
  $counts[$o.Outcome]++
  $selftest.UnitsWithSites += $o.WithSites; $selftest.UnitsDiff += $o.Diff
  $selftest.Sites += $o.Sites; $selftest.Named += $o.Named; $selftest.Broken += $o.Broken
  $t1.Sites += [int]$o.AllSites; $t1.Excluded += [int]$o.Excluded; $t1.Dropped += [int]$o.Dropped
  if ([int]$o.ParseDiags -gt 0) { $t1.ParseUnits++ }
  $t1.Culprits += [int]$o.Culprits; $t1.Compiles += [int]$o.Compiles
  $t1.Unbound += [int]$o.Unbound; if ([int]$o.Unbound -gt 0) { $t1.UnboundUnits++ }
  $t1.Invisible += [int]$o.Invisible; if ([int]$o.Invisible -gt 0) { $t1.InvisibleUnits++ }
  $t1.Mismatch += [int]$o.Mismatch; if ([int]$o.Mismatch -gt 0) { $t1.MismatchUnits++ }
  $localized += [int]$o.Localized
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
if ($Oracle) { $summary.Add("units whose stream came from the project analysis (-Oracle): $projectStream") }
$pass = $true
if ($Mode -eq 't1') {
  $summary.Add(("t1: sites={0} excluded (subrange type start, [ first, @, initializer start, source line info)={1} dropped={2} units with parse diagnostics={3}" -f
    $t1.Sites, $t1.Excluded, $t1.Dropped, $t1.ParseUnits))
}
if ($Mode -eq 't2') {
  $summary.Add(("t2: sites={0} excluded (inline var/const, labeled, asm, list calls, stored-body lines, source line info)={1} dropped={2} units with parse diagnostics={3}" -f
    $t1.Sites, $t1.Excluded, $t1.Dropped, $t1.ParseUnits))
}
if ($Mode -in @('t3', 't3x')) {
  $summary.Add(("{4}: sites={0} excluded (t1, t2 rules; print slots in an include used twice)={1} dropped={2} units with parse diagnostics={3}" -f
    $t1.Sites, $t1.Excluded, $t1.Dropped, $t1.ParseUnits, $Mode))
}
if ($Mode -in @('tq', 'tqs')) {
  $summary.Add(("{0}: sites={1} excluded (members outside reach, with, class methods, outer types, generic bodies, hidden qualifiers, merged overloads, positions)={2} dropped={3} unbound names={4} in {5} units, names bound to an invisible unit={6} in {7} units, units with parse diagnostics={8}" -f
    $Mode, $t1.Sites, $t1.Excluded, $t1.Dropped, $t1.Unbound, $t1.UnboundUnits, $t1.Invisible, $t1.InvisibleUnits, $t1.ParseUnits))
}
if ($Mode -in $memberModes) {
  $summary.Add(("{0}: sites={1} excluded (tq's rules{2}; members a cast cannot reach: type and class-reference bases, helpers, generic or hidden owners, stored bodies, record call results, untyped bases)={3} dropped={4} unbound names={5} in {6} units, names bound to an invisible unit={7} in {8} units, members PasTree's typing contradicts={9} in {10} units, units with parse diagnostics={11}" -f
    $Mode, $t1.Sites, $(if ($Mode -eq 'tqm') { '' } else { ' not applied' }), $t1.Excluded, $t1.Dropped, $t1.Unbound, $t1.UnboundUnits,
    $t1.Invisible, $t1.InvisibleUnits, $t1.Mismatch, $t1.MismatchUnits, $t1.ParseUnits))
}
if ($doLocalize) {
  $summary.Add(("localizer: culprits={0} variant compiles={1}" -f $t1.Culprits, $t1.Compiles))
}
if ($selfMode) {
  $summary.Add(("selftest: units with sites={0} diff={1} sites={2} named={3} broken={4}" -f
    $selftest.UnitsWithSites, $selftest.UnitsDiff, $selftest.Sites, $selftest.Named, $selftest.Broken))
  if ($doLocalize) { $summary.Add("selftest: sites localized alone=$localized of $($selftest.Sites)") }
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
