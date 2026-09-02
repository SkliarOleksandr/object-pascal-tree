# Working in this repository

`README.md` is what the library does and why it is shaped that way,
`docs/editor-features.md` the editor-facing features (navigation, completion,
rename), `docs/coverage.md` where PasTree is knowingly narrower than the
language, `docs/incremental-analysis.md` the reanalysis machinery. This file is
the rules that apply to every change, whatever it touches. The sibling
`pastree-lsp` repository keeps its own `CLAUDE.md` in the same shape - the
rules the two share are written the same way in both; keep them in step.

Every rule here is here because breaking it was silent. Keep the reasons when
editing this file - a rule with no reason gets "fixed" back.

## Do not commit until Alex has reviewed the diff

**Finish, report, stop.** Leave the work in the working tree, say what is
ready, and let Alex read the diff; the commit is his call. Never `git push` on
your own initiative.

The reason is commit hygiene, not caution: one reviewed change becomes one
commit, whereas committing each fix as it lands produces a chain of
`v0.x.y: fix the fix` commits that describe nothing. v0.15.0 shipped that way -
five commits for one feature - which is what prompted this rule (2026-09-02).

Exception: an explicitly **autonomous** session ("work autonomously", a
`/loop`, a scheduled run), where committing is part of finishing. Even there,
one commit per coherent green state, not one per edit.

## One version, moved in every commit

`PasTreeVersion` in `source/PasTree.Version.pas` moves on **every** commit -
PATCH mechanically, MINOR for a new capability or a public API. Thirteen
commits once slipped through with no bump. The sibling `pastree-lsp` checks
this value at its handshake (`cMinPasTreeVersion`) and its own floor is raised
against it, so a stale version defeats a real mismatch check.

## Line endings: CRLF for everything Delphi and cmd.exe read

**`.pas`, `.dpr`, `.dpk`, `.inc`, `.dproj`, `.dfm`, `.bat` are CRLF.** Docs
(`.md`, `LICENSE`), shell scripts and JSON are LF. Declared in
`.gitattributes`, identically in `pastree-lsp`.

A rule for **tools, not just people**: in Git Bash, `sed -i` and
`perl -0pi -e` READ through the crlf layer and WRITE without it, so an
in-place edit rewrites the whole file as LF even when the substitution touches
no line ending. The index is LF for everything, so `git diff` looks clean and
nothing complains - until RAD Studio re-saves the file and the next diff is the
entire file. `cmd.exe` can genuinely misparse an LF-only `.bat`, and every
build goes through one.

Two hooks now catch it: `.githooks/pre-commit` refuses such a commit (per
clone: `git config core.hooksPath .githooks`) and `.claude/hooks/eol-crlf.sh`
restores CRLF after each tool call. Verify by hand after any bulk text pass -
every `eol=crlf` row must read `w/crlf`:

```bash
git ls-files --eol | awk -F'\t' '$1 ~ /w[/]lf/ && $1 ~ /eol=crlf/ { print $2 }'
```

## English, plain hyphens, `local/` for working papers

**Everything written into this repository is in English** - docs, comments,
commit messages, log lines. Conversation is in whatever language suits;
artifacts are not, because they outlive it.

**Only the plain hyphen `-`. Never an em dash (U+2014) or en dash (U+2013)**,
anywhere. A non-ASCII dash in a Delphi literal compiles to mojibake in a file
with no BOM, and `cmd.exe` and the diff tools each render it differently.
Sweep before committing:

```bash
git ls-files | xargs grep -l -e "$(printf '\342\200\224')" -e "$(printf '\342\200\223')"
```

**Working documents go in `local/`, which is ignored** - audits, plans,
measurements, corpus paths, anything naming the closed project or a third-party
product. A finished conclusion belongs in a tracked document under `docs/`; the
working paper that produced it does not. The tracked files never name the
closed project or third-party products - that is what `local/` is for.

## Building and testing

- **The suites:** `tests\build.bat`, run from its own directory (three suites
  link `..\demo` units through relative `in` paths and only compile with that
  cwd; a wrong cwd reads as `F1026 File not found`). Deliberately **Win32** -
  they are unit suites over fixtures. It must end with `all suites passed`.
- **Everything else is Win64** (`dcc64`): `demo\build.bat`, `tools\`. A real
  project's closure needs more than a 32-bit address space - the client project
  holds 3.5 GB, and Win32's `EOutOfMemory` masquerades as an analyzer defect.
- **Every `.dcu` goes to `out\dcu\win32` or `out\dcu\win64`**, never next to a
  source: the same units compile for both platforms and the names collide.
- The demo is built by the scripts AND by the IDE: a new unit must be added to
  both the `.dpr` and the `.dproj`, or a green `build.bat` hides a broken IDE
  build.

## Two habits that pay for themselves here

**Start from the spec.** The language spec in `../object-pascal-spec` is
evidence: read the section before changing parser or resolver behaviour, and
where spec and code disagree, probe `dcc` rather than trusting either. A green
corpus is not coverage.

**Measure with range checks on.** A flaky measurement is usually an index bug
reading garbage, not a race - build the checked configuration before believing
a number or a diagnosis.
