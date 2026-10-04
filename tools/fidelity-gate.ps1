<#
.SYNOPSIS
  The fidelity gate: run it before committing any parser, preprocessor or
  printer change.

.DESCRIPTION
  One command over the corpora that decide whether PasTree's tree is dcc's
  (docs/parser-fidelity.md has the method; this is its routine check):

    build     PasTreeXform, PasTreeDcu, PasTreeTreeCheck and PasTreePrint,
              Win64, range and overflow checks on (a flaky verdict is an index
              bug reading garbage far more often than anything else)
    selftest  fidelity.ps1 -Mode ts -Localize over the self-host: the
              comparator must see every planted error and the localizer name
              it - a gate that cannot fail proves nothing
    tree      the tree checker (invariants I1-I8, the own-token table) and
              the structural printer (T3: the print against the parsed
              tokens, T3r: the print parsed back in two layouts) over the
              golden rows, the repository's own sources and the Studio
              source - and every file that does not parse clean
    t0f t1 t2 t3 t3x
              the compile-compare harness (fidelity.ps1) over the self-host,
              the Studio units and every extra corpus: each unit's rewrite
              must compile to the original's .dcu
    tqm       the resolver's rung over the self-host and the Studio units:
              every name PasTree bound written as the declaration it chose
              (`Unit.X`, `Self.X`, `TOwner(Base).X`) must compile to the
              original's .dcu; the counts of names it leaves unbound, binds
              to a unit not visible there, or types against its binding are
              floors (lines `@unbound`, `@invisible`, `@mismatch`; the
              Studio's as corpus `studio-rtl` or `studio-all`): above
              one fails, below one says lower it
    tqs tms   the rung's selftests over the Studio units: one wrong unit
              (tqs) or wrong owner type (tms) planted per routine, each to
              be seen and localized alone

  A harness stage judges each unit against the EXPECTATIONS - the outcomes
  known and explained today (tools\fidelity-gate.txt for the self-host and
  the Studio units, the corpus file's own list for an extra corpus). A unit
  no line names must be OK; a named one must show one of the outcomes its
  line allows. NONDET - dcc itself gave two .dcu for one text - is shown and
  never judged. A unit now OK where a line expects otherwise is reported as
  such (drop the line), never as a failure. The same for the tree stage: only
  the files the expectations list may parse with diagnostics, or fail to
  round-trip.

  -Studio rtl (the default) takes the units of source\rtl\BuildWinRTL.dpk,
  -Studio all every rtl/vcl/fmx unit the shipped library has a .dcu for,
  -Studio none leaves the Studio source out. The tree stage reads
  source\rtl or the whole source tree accordingly.

  An extra corpus is a .ps1 file returning a hashtable:
    Name      the corpus's name in the report
    Args      fidelity.ps1's parameters for it (List, UnitPath, Oracle, ...)
    Stages    optional, the harness stages to run (default t0f t1 t2 t3 t3x;
              tqm tqs tms on request)
    Expected  lines in the expectations format without the corpus column
  -Extra names such files; without it every *.ps1 in <repo>\local\gate\ is
  one (a working copy's own corpora - their paths never enter the
  repository).

  Outputs: <Out>\<stage>-<corpus>\ (fidelity.ps1's directories), the tree
  stage's reports, and gate.txt - the verdict. Exit code 0 = PASS.

.EXAMPLE
  .\fidelity-gate.ps1
.EXAMPLE
  .\fidelity-gate.ps1 -Stage tree,t1 -Studio all -NoBuild
#>
param(
  [ValidateSet('rtl', 'all', 'none')] [string] $Studio = 'rtl',
  [string[]] $Extra = @(),
  [ValidateSet('build', 'selftest', 'tree', 't0f', 't1', 't2', 't3', 't3x', 'tqm', 'tqs', 'tms')] [string[]] $Stage = @(),
  [string] $Out = '',
  [string] $Bds = 'C:\Program Files (x86)\Embarcadero\Studio\37.0',
  [int] $Jobs = 0,
  [switch] $NoBuild
)

$ErrorActionPreference = 'Stop'
$tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $tools
$harness = Join-Path $tools 'fidelity.ps1'
$bin = Join-Path $tools 'out64'
if ($Out -eq '') { $Out = Join-Path $repo 'out\fidelity-gate' }
$Out = [IO.Path]::GetFullPath($Out)
if ($Jobs -le 0) { $Jobs = [Math]::Max(1, [Environment]::ProcessorCount - 2) }
$allStages = @('build', 'selftest', 'tree', 't0f', 't1', 't2', 't3', 't3x', 'tqm', 'tqs', 'tms')
if ($Stage.Count -eq 0) { $Stage = $allStages }
if ($NoBuild) { $Stage = @($Stage | Where-Object { $_ -ne 'build' }) }
$modes = @('t0f', 't1', 't2', 't3', 't3x')
# The resolver's rung (docs/parser-fidelity.md sec. 6): tqm judged like the
# tree's modes, tqs and tms - selftests - by fidelity.ps1's own verdict.
$rungModes = @('tqm', 'tqs', 'tms')
$rungSelftests = @('tqs', 'tms')
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$started = Get-Date

$report = New-Object System.Collections.Generic.List[string]
$script:failed = $false
function Say([string] $Line) {
  $report.Add($Line)
  Write-Output $Line
}
function Fail([string] $Line) {
  $script:failed = $true
  Say $Line
}

# ---------------------------------------------------------------------------
# Expectations: `<corpus> <stages> <unit> <outcomes> <why>`, `#` comments.
# <stages> is `*` or a comma list, <outcomes> a `|` list. A T3r line has the
# stage t3r, a path relative to the tree root it was read from and FAIL.

$expect = @{}
function Add-Expectation([string] $Corpus, [string] $Line, [string] $Where) {
  $t = $Line.Trim()
  if ($t -eq '' -or $t.StartsWith('#')) { return }
  $f = $t -split '\s+', 4
  if ($f.Count -lt 4) { throw "${Where}: an expectation needs <stages> <unit> <outcomes> <why>: $t" }
  foreach ($s in ($f[0] -split ',')) {
    $key = "$Corpus|$($s.ToLower())|$($f[1].ToLower())"
    $expect[$key] = [pscustomobject]@{ Outcomes = @($f[2] -split '\|'); Why = $f[3]; Used = $false }
  }
}
function Find-Expectation([string] $Corpus, [string] $StageName, [string] $Unit) {
  foreach ($s in @($StageName, '*')) {
    $key = "$Corpus|$($s.ToLower())|$($Unit.ToLower())"
    if ($expect.ContainsKey($key)) { return $expect[$key] }
  }
  return $null
}
$lineNo = 0
foreach ($l in (Get-Content -LiteralPath (Join-Path $tools 'fidelity-gate.txt'))) {
  $lineNo++
  $t = $l.Trim()
  if ($t -eq '' -or $t.StartsWith('#')) { continue }
  $f = $t -split '\s+', 2
  Add-Expectation $f[0] $f[1] "fidelity-gate.txt($lineNo)"
}

# ---------------------------------------------------------------------------
# Corpora.

$corpora = New-Object System.Collections.Generic.List[object]
$selfList = Join-Path $Out 'units-self.txt'
Get-ChildItem -LiteralPath (Join-Path $repo 'source') -Filter '*.pas' | Sort-Object Name |
  ForEach-Object { $_.FullName } | Set-Content -LiteralPath $selfList
# The self-host has no tqs candidate (the merged-overload rule took its
# only one) and one tms candidate: its selftests are the Studio units'.
$corpora.Add([pscustomobject]@{ Name = 'self'; Stages = $modes + @('tqm')
  Args = @{ List = $selfList; Base = $true } })

$ns = 'Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win;Vcl;Vcl.Imaging;Vcl.Touch;Vcl.Samples;Vcl.Shell;System;Xml;Data;Datasnap;Web;Soap'
if ($Studio -ne 'none') {
  $lib = Join-Path $Bds 'lib\win64\release'
  $src = Join-Path $Bds 'source'
  $files = New-Object System.Collections.Generic.List[string]
  if ($Studio -eq 'rtl') {
    $dpk = Join-Path $src 'rtl\BuildWinRTL.dpk'
    foreach ($m in [regex]::Matches((Get-Content -LiteralPath $dpk -Raw), "\bin\s+'([^']+\.pas)'")) {
      $files.Add((Join-Path (Join-Path $src 'rtl') $m.Groups[1].Value))
    }
  } else {
    $seen = @{}
    foreach ($d in @('rtl', 'vcl', 'fmx')) {
      Get-ChildItem -LiteralPath (Join-Path $src $d) -Filter '*.pas' -Recurse | Sort-Object FullName |
        ForEach-Object {
          $n = $_.BaseName.ToLower()
          if (-not $seen.ContainsKey($n)) { $seen[$n] = $true; $files.Add($_.FullName) }
        }
    }
  }
  # A unit the shipped library has no .dcu for is not built for Win64.
  $studioList = Join-Path $Out 'units-studio.txt'
  @($files | Where-Object { Test-Path -LiteralPath (Join-Path $lib ([IO.Path]::GetFileNameWithoutExtension($_) + '.dcu')) } |
    Sort-Object) | Set-Content -LiteralPath $studioList
  $corpora.Add([pscustomobject]@{ Name = 'studio'; Stages = $modes + $rungModes
    Args = @{ List = $studioList; Namespaces = $ns; Oracle = $true } })
}

if ($Extra.Count -eq 0) {
  $gateDir = Join-Path $repo 'local\gate'
  if (Test-Path -LiteralPath $gateDir) {
    $Extra = @(Get-ChildItem -LiteralPath $gateDir -Filter '*.ps1' | Sort-Object Name | ForEach-Object { $_.FullName })
  }
}
foreach ($e in $Extra) {
  $c = & $e
  if ($null -eq $c.Name -or $null -eq $c.Args) { throw "${e}: the corpus file must return Name and Args" }
  $st = $modes
  if ($null -ne $c.Stages) { $st = @($c.Stages) }
  foreach ($l in @($c.Expected)) { if ($null -ne $l) { Add-Expectation $c.Name $l $e } }
  $corpora.Add([pscustomobject]@{ Name = $c.Name; Stages = $st; Args = $c.Args })
}

Say ("fidelity gate  {0:yyyy-MM-dd HH:mm}  repo {1}  studio {2}  corpora {3}  jobs {4}" -f $started, $repo,
  $Studio, (($corpora | ForEach-Object { $_.Name }) -join ' '), $Jobs)

# ---------------------------------------------------------------------------
# build

if ($Stage -contains 'build') {
  $dcc = Join-Path $Bds 'bin\dcc64.exe'
  # dcc creates neither directory, and says only F2039.
  New-Item -ItemType Directory -Force -Path (Join-Path $repo 'out\dcu\win64') | Out-Null
  New-Item -ItemType Directory -Force -Path $bin | Out-Null
  foreach ($t in @('PasTreeXform', 'PasTreeDcu', 'PasTreeTreeCheck', 'PasTreePrint')) {
    $log = Join-Path $Out "build-$t.log"
    Push-Location $tools
    try {
      $o = & $dcc -B -Q '-$R+' '-$Q+' "-U$Bds\lib\win64\release;..\source" '-NSSystem;System.Win;Winapi;Data;Xml' `
        '-N0..\out\dcu\win64' -Eout64 "$t.dpr" 2>&1
      $code = $LASTEXITCODE
    } finally { Pop-Location }
    $o | Set-Content -LiteralPath $log
    if ($code -ne 0) {
      Fail "build     $t  FAIL (exit $code, $log)"
      Say (($o | Select-Object -Last 5) -join [Environment]::NewLine)
      Set-Content -LiteralPath (Join-Path $Out 'gate.txt') -Value $report
      exit 1
    }
    Say "build     $t  OK"
  }
}

# ---------------------------------------------------------------------------
# selftest

if ($Stage -contains 'selftest') {
  $dir = Join-Path $Out 'selftest'
  & $harness -List $selfList -Mode ts -Localize -Base -Out $dir -Tools $bin -Jobs $Jobs *> "$dir.log"
  $sum = @(Get-Content -LiteralPath (Join-Path $dir 'summary.txt'))
  $loc = @($sum | Where-Object { $_ -like 'selftest: sites localized alone=*' })
  $ok = ($sum[-1] -eq 'PASS')
  if ($ok -and $loc.Count -eq 1 -and $loc[0] -match '=(\d+) of (\d+)$') { $ok = ($Matches[1] -eq $Matches[2]) }
  $line = "selftest  self  $(($sum | Where-Object { $_ -like 'selftest: units*' }) -join ''); $($loc -join '')"
  if ($ok) { Say "$line  PASS" } else { Fail "$line  FAIL ($dir)" }
}

# ---------------------------------------------------------------------------
# tree

if ($Stage -contains 'tree') {
  $roots = New-Object System.Collections.Generic.List[object]
  $roots.Add([pscustomobject]@{ Corpus = 'golden'; Root = ''; Args = @('-golden') })
  foreach ($d in @('source', 'tools', 'tests', 'demo')) {
    $p = Join-Path $repo $d
    if (Test-Path -LiteralPath $p) { $roots.Add([pscustomobject]@{ Corpus = 'self'; Root = $p; Args = @($p, '-p:Win64') }) }
  }
  if ($Studio -ne 'none') {
    $p = Join-Path $Bds 'source'
    if ($Studio -eq 'rtl') { $p = Join-Path $p 'rtl' }
    $roots.Add([pscustomobject]@{ Corpus = 'studio'; Root = (Join-Path $Bds 'source'); Args = @($p, '-p:Win64') })
  }
  $unclean = @{}
  foreach ($r in $roots) {
    $name = $r.Corpus
    if ($r.Root -ne '' -and $r.Corpus -eq 'self') { $name = 'self-' + (Split-Path -Leaf $r.Root) }
    $a = $r.Args
    $relOf = {
      param([string] $File)
      if ($r.Root -eq '') { return $File }
      return [IO.Path]::GetFullPath($File).Substring([IO.Path]::GetFullPath($r.Root).TrimEnd('\').Length + 1)
    }
    # The tree checker: any violation fails (clean files or not - a file
    # with parse diagnostics keeps the invariants too). -v lists every parse
    # diagnostic: a file of valid code that stops parsing clean is the
    # plainest regression there is, and the printer's checks never see it
    # (T3 and T3r judge clean files only).
    $log = Join-Path $Out "tree-check-$name.txt"
    & (Join-Path $bin 'PasTreeTreeCheck.exe') @a -v > $log 2>&1
    $code = $LASTEXITCODE
    $v = @(Select-String -LiteralPath $log -Pattern '^Violations:\s+(.*)$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    $u = @(Select-String -LiteralPath $log -Pattern 'UNLISTED (\d+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    $bad = New-Object System.Collections.Generic.List[string]
    if ($code -ne 0) { $bad.Add("PasTreeTreeCheck exit $code") }
    $first = [ordered]@{}
    foreach ($m in (Select-String -LiteralPath $log -Pattern '^(.+?)\(\d+,\d+\): parse: (.*)$')) {
      $rel = & $relOf $m.Matches[0].Groups[1].Value
      if (-not $first.Contains($rel)) { $first[$rel] = $m.Line }
    }
    # The golden rows' diagnostics are theirs: the error-mode rows break on
    # purpose, and ParserSmoke judges each row's own count.
    if ($r.Corpus -eq 'golden') { $first.Clear() }
    $expected = 0
    foreach ($rel in $first.Keys) {
      $unclean["$($r.Corpus)|$($rel.ToLower())"] = $true
      $x = Find-Expectation $r.Corpus 'parse' $rel
      if ($null -ne $x) { $x.Used = $true; $expected++ } else { $bad.Add("parse diagnostics: $($first[$rel])") }
    }
    $line = "tree      check  $name  violations: $($v -join ''); unlisted own tokens: $($u -join ''); files with parse diagnostics: $($first.Count), $expected expected"
    if ($bad.Count -eq 0) { Say "$line  PASS" } else {
      Fail "$line  FAIL ($log)"
      foreach ($b in $bad) { Say "            $b" }
    }
    # The printer: no T3 defect ever; T3r only where expected.
    $log = Join-Path $Out "tree-print-$name.txt"
    & (Join-Path $bin 'PasTreePrint.exe') @a -max:500 > $log 2>&1
    $code = $LASTEXITCODE
    $t3 = @(Select-String -LiteralPath $log -Pattern '^T3: .*, (\d+) defects in (\d+) files' | ForEach-Object { $_.Matches[0] })
    $t3r = @(Select-String -LiteralPath $log -Pattern '^T3r: (.*)$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    $exc = @(Select-String -LiteralPath $log -Pattern 'exceptions: (\d+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    $bad = New-Object System.Collections.Generic.List[string]
    $expected = 0
    if ($code -gt 1 -or $t3.Count -ne 1 -or $t3r.Count -ne 1) { $bad.Add("PasTreePrint exit $code, no summary") }
    elseif ($t3[0].Groups[1].Value -ne '0') { $bad.Add("T3 defects: $($t3[0].Groups[1].Value) in $($t3[0].Groups[2].Value) files") }
    if (($exc | Where-Object { $_ -ne '0' }).Count -gt 0) { $bad.Add("exceptions: $($exc -join ' ')") }
    foreach ($m in (Select-String -LiteralPath $log -Pattern '^(.+?): T3r: (.*)$')) {
      $rel = & $relOf $m.Matches[0].Groups[1].Value
      $x = Find-Expectation $r.Corpus 't3r' $rel
      if ($null -ne $x) { $x.Used = $true; $expected++ } else { $bad.Add("T3r: $rel - $($m.Matches[0].Groups[2].Value)") }
    }
    $line = "tree      print  $name  T3r: $($t3r -join ''), $expected expected"
    if ($bad.Count -eq 0) { Say "$line  PASS" } else {
      Fail "$line  FAIL ($log)"
      foreach ($b in $bad) { Say "            $b" }
    }
  }
  # An expectation whose file now parses clean, or round-trips, is stale -
  # but a T3r one is not judged while its file has parse diagnostics.
  foreach ($k in @($expect.Keys | Where-Object { $_ -like '*|t3r|*' -or $_ -like '*|parse|*' })) {
    $f = $k -split '\|'
    $inRun = ($f[0] -eq 'self') -or ($f[0] -eq 'studio' -and $Studio -ne 'none')
    if ($inRun -and -not $expect[$k].Used -and ($Studio -eq 'all' -or $f[2] -like 'rtl\*') -and
        -not $unclean.ContainsKey("$($f[0])|$($f[2])")) {
      $what = 'now round-trips'
      if ($f[1] -eq 'parse') { $what = 'now parses clean' }
      Say "            $what (drop the expectation): $($f[2])"
    }
  }
}

# ---------------------------------------------------------------------------
# t0f t1 t2 t3 t3x

foreach ($m in ($modes + $rungModes)) {
  if ($Stage -notcontains $m) { continue }
  foreach ($c in $corpora) {
    if ($c.Stages -notcontains $m) { continue }
    $dir = Join-Path $Out "$m-$($c.Name)"
    $a = $c.Args.Clone()
    if (-not $a.ContainsKey('Jobs')) { $a['Jobs'] = $Jobs }
    # Every planted site must be localized alone, and a unit can hold one per
    # routine - Vcl.ComCtrls' TListColumn plants ~60 that each stop the
    # compile: the localizer's default 64 compiles do not reach them all.
    if ($rungSelftests -contains $m) { $a['Localize'] = $true; $a['LocalizeBudget'] = 512 }
    & $harness -Mode $m -Out $dir -Tools $bin @a *> "$dir.log"
    $resultsFile = Join-Path $dir 'results.txt'
    if (-not (Test-Path -LiteralPath $resultsFile)) {
      Fail "$($m.PadRight(9)) $($c.Name)  FAIL - the harness wrote no results ($dir.log)"
      Say ((Get-Content -LiteralPath "$dir.log" | Select-Object -Last 5) -join [Environment]::NewLine)
      continue
    }
    $counts = [ordered]@{}
    $ok = 0; $asExpected = 0
    $bad = New-Object System.Collections.Generic.List[string]
    $fixed = New-Object System.Collections.Generic.List[string]
    $nondet = New-Object System.Collections.Generic.List[string]
    foreach ($l in (Get-Content -LiteralPath $resultsFile)) {
      $f = $l -split '  ', 3
      $outcome = $f[0]; $unit = $f[1]
      $counts[$outcome] = 1 + [int]$counts[$outcome]
      $x = Find-Expectation $c.Name $m $unit
      if ($outcome -eq 'OK') {
        $ok++
        if ($null -ne $x -and $x.Outcomes -notcontains 'OK') { $fixed.Add("$unit (expected $($x.Outcomes -join '|'): $($x.Why))") }
      } elseif ($null -ne $x -and $x.Outcomes -contains $outcome) {
        $asExpected++
      } elseif ($outcome -eq 'NONDET') {
        # dcc itself varied on this unit - the original's compiles disagreed,
        # or the copy compiled once to the original's .dcu (then the rewrite
        # IS the same program). Not a verdict on the tree either way; shown,
        # never failed, so the gate does not flicker with dcc.
        $nondet.Add($l)
      } else {
        $bad.Add($l)
      }
    }
    $sum = (($counts.Keys | ForEach-Object { "$($counts[$_]) $_" }) -join ', ')
    if ($rungSelftests -contains $m) {
      # Every planted site is wrong: a unit with one must DIFF (or fail to
      # compile), and the localizer name it alone - fidelity.ps1's verdict.
      $s = @(Get-Content -LiteralPath (Join-Path $dir 'summary.txt'))
      $loc = @($s | Where-Object { $_ -like 'selftest: sites localized alone=*' })
      $ok = ($s[-1] -eq 'PASS')
      if ($ok -and $loc.Count -eq 1 -and $loc[0] -match '=(\d+) of (\d+)$') { $ok = ($Matches[1] -eq $Matches[2]) }
      $line = "$($m.PadRight(9)) $($c.Name)  $(($s | Where-Object { $_ -like 'selftest: units*' }) -join ''); $($loc -join '')"
      if ($ok) { Say "$line  PASS" } else { Fail "$line  FAIL ($dir)" }
      continue
    }
    $line ="$($m.PadRight(9)) $($c.Name)  $sum; $asExpected as expected, $($nondet.Count) not judged, $($bad.Count) not"
    if ($bad.Count -eq 0) { Say "$line  PASS" } else {
      Fail "$line  FAIL ($dir)"
      foreach ($b in $bad) { Say "            $b" }
    }
    foreach ($b in $nondet) { Say "            not judged: $b" }
    foreach ($b in $fixed) { Say "            now OK (drop the expectation): $b" }
    if ($rungModes -contains $m) {
      # The rung's measures: names it could not judge because PasTree bound
      # them to nothing, to a unit not visible at the name, or typed a
      # member's base against its own binding. Each is a floor - a resolver
      # change that raises one is a regression no .dcu shows.
      $s = (Get-Content -LiteralPath (Join-Path $dir 'summary.txt')) -join ' '
      $measures = [ordered]@{
        '@unbound' = 'unbound names=(\d+)'
        '@invisible' = 'bound to an invisible unit=(\d+)'
        '@mismatch' = 'typing contradicts=(\d+)'
      }
      foreach ($k in $measures.Keys) {
        if ($s -notmatch $measures[$k]) { continue }
        $n = [int]$Matches[1]
        # The Studio's floors depend on its unit list: `studio-rtl` or
        # `studio-all` in the expectations.
        $mc = $c.Name
        if ($mc -eq 'studio') { $mc = "studio-$Studio" }
        $x = Find-Expectation $mc $m $k
        $floor = 0
        if ($null -ne $x) { $x.Used = $true; $floor = [int]$x.Outcomes[0] }
        if ($n -gt $floor) { Fail "            $k $n above the floor $floor  FAIL" }
        elseif ($n -lt $floor) { Say "            $k $n below the floor $floor (lower it)" }
      }
    }
  }
}

$elapsed = ((Get-Date) - $started).TotalSeconds
Say ("{0}  ({1:N0} s)" -f $(if ($script:failed) { 'FAIL' } else { 'PASS' }), $elapsed)
Set-Content -LiteralPath (Join-Path $Out 'gate.txt') -Value $report
if ($script:failed) { exit 1 }
exit 0
