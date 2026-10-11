# Testing-availability baseline for scout-rig (step 1 of 8)

Pre-edit, read-only investigation record. Purpose: authoritative baseline of
current suite behavior, actual runtime-selection code paths, and the exact
contract of the installed `Scout::Testing::Availability` primitives, so the
implementation steps (2-8) can code against verified facts instead of
re-deriving them.

All commands were run from `/bulk/mvazque2/git/scout-rig` unless noted.
Raw scratch outputs live under `tmp/` (see Baseline suite run and
Installed scout-essentials primitive contract). No repository file other
than this note was created; no tracked repository file was modified
(verified at the end, see Repo identity).

Divergences from the "Prior investigation (pinned HEAD 290ee22)" facts given
in the delegation are marked **DIVERGENCE** throughout and summarized in
Conclusions for the implementer.

---

## Repo identity

Working tree recorded: `/bulk/mvazque2/git/scout-rig` (the writable checkout
named in the task).

`/home/mvazque2/git/scout-rig` does **not exist**; `/home/mvazque2/git`
itself exists but contains no `scout-rig` entry, so there is no second
checkout to avoid here. (**DIVERGENCE** from the Current-state claim that two
checkouts exist; harmless - nothing outside `/bulk/mvazque2/git/scout-rig`
was touched.)

```
$ git rev-parse HEAD
386954a463d8e1a4d335d366836af3cc8c68c584
$ git log -1 --format='%H %ci %s'
386954a463d8e1a4d335d366836af3cc8c68c584 2026-10-10 10:42:26 +0200 Explain how to add extensions

$ git status --short
 M doc/developer/PythonWorkflowInternals.md
 M doc/user/DefiningPythonTasks.md
 M lib/scout/python/script.rb
 M lib/scout/workflow/python/task.rb
 M test/scout/workflow/python/test_task.rb
```

**The tree is NOT clean.** Five files carry uncommitted modifications that
predate this investigation (present before any command here ran; this task
performed no edits to tracked files). `git diff --stat`:

```
 doc/developer/PythonWorkflowInternals.md | 10 +++++
 doc/user/DefiningPythonTasks.md          | 25 ++++++++++++
 lib/scout/python/script.rb               | 13 +++++-
 lib/scout/workflow/python/task.rb        |  3 +-
 test/scout/workflow/python/test_task.rb  | 74 ++++++++++++++++++++++++++++++--
 5 files changed, 118 insertions(+), 7 deletions(-)
```

The worktree adds 4 new tests in `test/scout/workflow/python/test_task.rb`
(`test_runtime_task_receives_its_step_files_directory`,
`test_run_file_does_not_inherit_stale_files_directory`,
`test_run_file_explicit_environment_overrides_stale_parent_value`,
`test_run_file_unrelated_environment_does_not_inherit_stale_files_directory`)
plus the `run_file` env-stripping change in `lib/scout/python/script.rb` /
`lib/scout/workflow/python/task.rb` - the "Python exception support /
extensions" work continuing past HEAD. Three stashes also exist
(`stash@{0}` on `c3f83c8`, `stash@{1}` on `5a84155`, `stash@{2}` on
`713e64f`). Any later step must decide whether to record HEAD or
HEAD+worktree as its baseline; the counts below reflect **HEAD+worktree**
(what actually ran).

`290ee22` (the prior investigation's pin, `290ee22 2026-07-31 14:27:09 +0200
Revamped documentation`) is 6 commits behind the current HEAD in this
branch's history (50 commits total in `main`) - that explains several
divergences below.

```
$ ruby -v
ruby 3.3.1 (2024-04-23 revision c56cd86388) [x86_64-linux]

$ gem list scout-essentials
scout-essentials (1.9.1, 1.9.0, 1.8.8, 1.8.7, 1.8.6, 1.8.5)

$ gem which scout/testing/availability
/home/mvazque2/git/scout-essentials/lib/scout/testing/availability.rb
```

Note on `gem which`: it resolves through the ambient `RUBYOPT` include path
(see Environment inventory), which puts `/home/mvazque2/git/scout-essentials/lib`
ahead of the installed gems. The **installed** scout-essentials 1.9.1 gem
(`/home/mvazque2/.rvm/gems/ruby-3.3.1/gems/scout-essentials-1.9.1`) does **not**
ship `lib/scout/testing/availability.rb` (verified: the file is absent for
the 1.9.1, 1.9.0 and 1.8.8 gem dirs; `gem contents scout-essentials -v 1.9.1`
lists no availability file). In this environment the primitive is provided
by the **scout-essentials git checkout** (reference repo HEAD `759db2e`,
"More Array fingerprint", 2026-10-02), where
`lib/scout/testing/availability.rb` is a staged-but-uncommitted addition
(`git status` in that repo shows `A  lib/scout/testing/availability.rb`;
`git ls-files lib/scout/testing/` there lists
`lib/scout/testing/availability.rb` and `lib/scout/testing/scout_state.rb`).
This matters for step 8 (packaging): a released gem today would not carry
the primitive at all.

`VERSION` file: `0.2.6`.

---

## Environment inventory

```
$ command -v python python3 rscript
/usr/bin/python
/usr/bin/python3
(no rscript; only uppercase Rscript:)
$ command -v Rscript
/usr/lib/R/bin/Rscript
$ Rscript --version
Rscript (R) version 4.4.3 (2025-02-28)
```

`command -v rscript` finds nothing - **R's binary is `Rscript`, not
`rscript`** - so any probe must look for `Rscript` (the handoff's
`rscript_executable` already does).

All of `python`, `python3`, `/usr/bin/python3` are Python 3.13.3.

Optional-module importability for the default `python3` (exit status
recorded):

```
$ python3 -c "import numpy"; echo exit=$?   -> exit=0    (numpy 2.2.3)
$ python3 -c "import pandas"; echo exit=$?  -> exit=0    (pandas 2.2.3)
$ python3 -c "import torch"; echo exit=$?
Traceback (most recent call last):
  File "<string>", line 1, in <module>
ModuleNotFoundError: No module named 'torch'
exit=1
```

Ruby side: pycall 1.5.2 and pycall_thread 0.1.3 are installed and loadable;
test-unit is **3.6.1**.

```
$ env | grep -E '^(SCOUT|PYTHON)'
SCOUT_CHAT_DIR=/bulk/mvazque2/git/scout-rig
```

No `PYTHON*` variables are exported into the ambient environment - no
`PYTHONHOME`, no `PYTHONPATH`, no `ENV['PYTHON']`. (`PYTHONHOME` is still
*set later by PyCall.init at runtime*; see Runtime selection facts.)

Other environment facts that shape runs from this directory:

```
GEM_HOME=/home/mvazque2/.rvm/gems/ruby-3.3.1
GEM_PATH=/home/mvazque2/.rvm/gems/ruby-3.3.1:/home/mvazque2/.rvm/gems/ruby-3.3.1@global
RUBYOPT=-I/home/mvazque2/software/opt/rubygems/lib ... -I /home/mvazque2/git/scout-essentials/lib
```

The `RUBYOPT` tail includes `-I /home/mvazque2/git/scout-essentials/lib`
(and `/home/mvazque2/git/scout-rig/lib`), which is why plain
`ruby -rscout/testing/availability` resolves the checkout, not the installed
gem.

---

## Baseline suite run

Command (stock environment, no `PYTHON`/`PATH` manipulation):

```bash
( rake test 2>&1; echo "RAKE_EXIT=$?" ) > tmp/testing-availability-baseline-rake-test.log
```

Full raw output (655 lines, ANSI included) is at
`tmp/testing-availability-baseline-rake-test.log` in this repo.

- `RAKE_EXIT=1` - rake aborts because the loader exits non-zero.
- Test::Unit summary (verbatim, ANSI stripped):

```
23 tests, 83 assertions, 0 failures, 1 errors, 0 pendings, 0 omissions, 0 notifications
```

- 0 failures, 0 omissions, 0 pendings; exactly **1 error**.

Verbatim error excerpt (ANSI stripped):

```
===============================================================================
Error: test_binding(TestPython): PyCall::PyError: <class 'ModuleNotFoundError'>: No module named 'torch'
/home/mvazque2/.rvm/gems/ruby-3.3.1/gems/pycall-1.5.2/lib/pycall.rb:82:in `import_module'
/home/mvazque2/.rvm/gems/ruby-3.3.1/gems/pycall-1.5.2/lib/pycall/import.rb:18:in `pyimport'
/bulk/mvazque2/git/scout-rig/test/scout/test_python.rb:113:in `block in test_binding'
     110:   def test_binding
     111:     raised = false
     112:     ScoutPython.binding_run do
  => 113:       pyimport :torch
     114:       pyfrom :torch, import: ["nn"]
     115:       begin
     116:         torch
```

and the rake failure line:

```
Command failed with status (1): [ruby -w -I"lib:lib:test" .../rake_test_loader.rb ...]
rake aborted!
Tasks: TOP => test
RAKE_EXIT=1
```

Attribution: the single error is **optional-runtime-missing**
(`ModuleNotFoundError: No module named 'torch'` raised from `pyimport :torch`
inside the test body - torch is not a declared dependency anywhere in the
repo; `python/pyproject.toml` requires only `pandas`). It is **not** a code
failure: no shipped-code regression is involved, the error escapes the
test's own `begin/rescue` (which guards a *different*, later `torch` use at
`test/scout/test_python.rb:116+`), and the suite's only exit-1 cause is this
one error. Everything else (22 tests, 83 assertions) passed.

(**DIVERGENCE**: the prior investigation recorded "9 tests with 1 error".
At HEAD+worktree the suite runs **23 tests** - the Python-task batch-mode
and `run_file` env tests added after `290ee22` are present in the working
tree. The error itself is unchanged: same `test_binding`, same torch cause.
Note also that the committed doc `doc/user/TestingAndPackaging.md` still
describes the 9-test/1-error state, so that doc is stale relative to the
worktree.)

---

## Test-file audit

Files audited: `test/test_helper.rb`, `test/scout/test_python.rb`,
`test/scout/python/test_script.rb`, `test/scout/python/test_run.rb`,
`test/scout/python/test_util.rb`,
`test/scout/workflow/python/test_task.rb`,
`test/scout/workflow/test_python.rb`, `Rakefile`, `scout-rig.gemspec`.

There is **no** `test/python/` directory (the script/run/util helper tests
live under `test/scout/python/`); `test/scout/workflow/python/` holds
`test_task.rb` only. (**DIVERGENCE** from the delegation's "files under
test/python/" phrasing - trivial naming point, recorded so nobody hunts for
a nonexistent dir.)

### Per-file counts and prerequisites

Counts are of `def test_*` (active) vs `def _test_*` / `def __test_*`
(disabled, i.e. invisible to Test::Unit discovery). "worktree" = what
actually ran in the baseline; "(HEAD)" notes where the committed tree
differs.

| File | Active (worktree) | `_`-disabled | Route | Optional prerequisites |
|---|---|---|---|---|
| `test/test_helper.rb` | - (no tests) | - | - | none; provides helpers + setup/teardown isolation only |
| `test/scout/python/test_run.rb` | 0 | 1 (`def __test_run_threaded`) | in-process PyCall | (would need) `sys` only |
| `test/scout/python/test_script.rb` | 4 | 0 | subprocess (`ScoutPython.script`) | numpy, pandas, `python/scout` importable via `PYTHONPATH` (auto) |
| `test/scout/python/test_util.rb` | 2 | 0 | in-process PyCall | numpy (`test_numpy`), pandas (`tsv2df` path) |
| `test/scout/test_python.rb` | 1 (`test_binding`) | 10 | in-process PyCall | **torch** (`test_binding`); the 10 disabled ones also reference numpy/keras/torch but never run |
| `test/scout/workflow/python/test_task.rb` | 15 (11 at HEAD; 4 added in worktree) | 0 | subprocess (`run_file`/`python_task`) | stdlib only (`typing`) |
| `test/scout/workflow/test_python.rb` | 1 | 0 | subprocess (imports `scout` python pkg) | numpy, pandas (`python/scout/__init__.py` imports pandas at module load) |
| **Total** | **23** | **11** | | |

Verbatim disabled-method listing in `test/scout/test_python.rb` (line: name):
`6 _test_python`, `45 _test_run_log`, `69 _test_keras`, `79 _test_keras_import`,
`89 _test_iterate`, `105 _test_lambda`, `134 _test_import_method`,
`139 _test_class_new_obj`, `144 _test_single`, `151 _test_threaded` - plus the
one active `110 test_binding`. 11 methods total, 10 disabled. (Matches the
prior fact; it is one of the few prior facts that still holds exactly.)

### Skip logic

None, anywhere. `grep -rn "omit\|skip" test/` returns nothing (no `omit`, no
`skip`, no environment guards). `test_helper.rb` (59 lines, read in full)
does isolation only - `setup`/`teardown` `Open.rm_rf` the tmpdir and redirect
`TmpFile`, `Persist`, `Open.remote_cache` and `Workflow.directory` there -
plus progress-bar quieting. It contains **zero** interpreter/package
selection or skip logic; the suite is plain Test::Unit (no minitest/rspec).
Renaming to a `_` prefix is the only disabling mechanism used in the repo.

### Rakefile / gemspec facts

`Rakefile` (`Rake::TestTask`):

```ruby
Rake::TestTask.new(:test) do |test|
  test.libs << 'lib' << 'test'
  test.pattern = 'test/**/test_*.rb'
  test.verbose = true
end
task :default => :test
```

`scout-rig.gemspec` (Juwelier): name `scout-rig`, `s.add_runtime_dependency
'pycall', '> 0'`, dev dependency `juwelier ~> 2.1.0`. **torch is not
declared anywhere** (neither runtime nor development), consistent with the
attribution above. Gemspec file count as loaded: 39 files.

Gemspec staleness (recorded, not fixed - per constraint):

- 27 files tracked in git but **missing from the gemspec file list**, i.e.
  not shipped: all of `doc/` (`doc/user/...` 9 files incl.
  `TestingAndPackaging.md`, `PythonEnvironments.md`; `doc/developer/...` 5
  files; `doc/Improvements.md`, `doc/StartHere.md`), `python/scout/task_errors.py`,
  all 8 `research/*.md`, and `.gitignore`.
- 2 files listed in the gemspec but **not in git**: `doc/Python.md`,
  `doc/PythonWorkflow.md` (stale remnants; they do not exist on disk).

(The gemspec regenerates via `rake gemspec` from the Juwelier Rakefile; that
task was NOT run, per constraints. Note the note file you are reading is in
`research/`, which the gemspec currently excludes from the gem.)

---

## Runtime selection facts

From grep over `lib/` and `test/` (all hits quoted; there are no others):

**`ENV['PYTHON']` / `ENV["PYTHON"]` - zero hits in `lib/` and `test/`.**

The only place `ENV['PYTHON']` is consulted is inside the installed **pycall
gem**, not scout-rig:

```
/home/mvazque2/.rvm/gems/ruby-3.3.1/gems/pycall-1.5.2/lib/pycall/init.rb:24:
  def self.init(python = ENV['PYTHON'])
```

scout-rig's own entry point is:

```ruby
# lib/scout/python.rb:15
  def self.init_scout
    if ! defined?(@@__init_scout_python) || ! @@__init_scout_python
      PyCall.init
```

i.e. `PyCall.init` is called with no argument, so pycall falls back to
`ENV['PYTHON']` (nil here) and then to PATH lookup `python3`/`python` inside
`LibPython::Finder.find_libpython`. `PyCall.init` is referenced exactly once
in scout-rig code (`lib/scout/python.rb:15`).

**Literal `python` spawn sites (subprocess route):**

```ruby
# lib/scout/python/script.rb:105  (ScoutPython.script)
      CMD.cmd_log("env PYTHONPATH=#{path_env} python", {in: text})
```

```ruby
# lib/scout/python/script.rb:112-119  (ScoutPython.run_file)
  def self.run_file(file, arg_str, env: {})
    path_env = ScoutPython.paths * ":"
    # Non-Step calls must not inherit a stale sidecar from the parent process.
    env_assignments = env.map { |name, value| "#{name}=#{Shellwords.escape(value.to_s)}" }.join(' ')
    command = 'env'
    command << ' -u SCOUT_JOB_FILES_DIR'
    command << " PYTHONPATH=#{Shellwords.escape(path_env)}"
    command << " #{env_assignments}" unless env_assignments.empty?
    command << " python #{Shellwords.escape(file.to_s)} #{arg_str}"
    CMD.cmd(command)
  end
```

Both spawn the literal command `python` resolved from `PATH`, with
`PYTHONPATH` set to `ScoutPython.paths * ":"` (`lib/scout/python/paths.rb`
seeds `ScoutPython.paths` from `Scout.python.find_all`). `ENV['PYTHON']` is
never consulted on this route. `python_task` registration/execution goes
through these same helpers: `lib/scout/workflow/python/task.rb:33`
(`read_python_metadata` -> `ScoutPython.run_file file, '--scout-metadata'`),
`:45` (`read_python_metadata_files` -> runner.py), and `:153` (task block ->
`ScoutPython.run_file file, ..., env: { 'SCOUT_JOB_FILES_DIR' => ... }`).
There are no other `python` spawn sites (`grep -rn "'python'\|\"python\"" lib/`
returns only the two `script.rb` lines above).

**PYTHONHOME / PYTHONPATH mutation:** scout-rig never touches `PYTHONHOME`
(zero hits in `lib/` and `test/`) and never sets `PYTHONPATH` as a Ruby env
var; it only *prepends* its paths by passing `PYTHONPATH=...` on the `env`
command line in the two sites above. The process-wide `PYTHONHOME`
mutation happens **inside pycall**, at:

```
/home/mvazque2/.rvm/gems/ruby-3.3.1/gems/pycall-1.5.2/lib/pycall/libpython/finder.rb:46-51
          python_home = if !ENV.key?("PYTHONHOME") || use_conda
            ...
          end
          ENV["PYTHONHOME"] = python_home
```

So after any in-process `PyCall.init`, the Ruby process's `ENV['PYTHONHOME']`
points at the embedded interpreter's home - exactly the trap the handoff
describes for mixed-route runs.

**`SCOUT_TEST_` hits: none.** `grep -rn "SCOUT_TEST_"` over the repo
(rb/md/py) returns zero hits. `SCOUT_TEST_PYTHON` / `SCOUT_TEST_RSCRIPT` do
not exist in scout-rig today, as expected.

Net runtime-selection matrix, verified against the code above:

| Route | Entry points | Interpreter chosen by | `ENV['PYTHON']`? | Env effect |
|---|---|---|---|---|
| Embedded (PyCall) | `ScoutPython.run/run_direct/binding_run/...` via `lib/scout/python.rb:15 PyCall.init` | pycall: `ENV['PYTHON']` else PATH `python3`/`python` | **yes** (in pycall) | **sets `ENV['PYTHONHOME']`** |
| Subprocess | `ScoutPython.script` (`script.rb:105`), `ScoutPython.run_file` (`script.rb:119`), `python_task` (`task.rb:33/45/153`) | literal `python` from PATH | **no** | `env PYTHONPATH=<paths> [-u SCOUT_JOB_FILES_DIR] [assignments]` |

This matches the prior investigation and the handoff's matrix; re-verified
with current line numbers above.

---

## Installed scout-essentials primitive contract

Probe file `tmp/primitive_probe.rb`; verbatim output `tmp/primitive_probe.log`
(both under this repo's `tmp/`). Run as `ruby tmp/primitive_probe.rb` from
the repo root; `PROBE_EXIT=0`. Probe core (full source in `tmp/`):

```ruby
require 'scout/testing/availability'
# prints provider info and module surface, then exercises:
Scout::Testing::Availability.executable?('ruby')
Scout::Testing::Availability.executable?('definitely_missing_xyz_123')
Scout::Testing::Availability.run_command(%w[true], timeout: 5)
Scout::Testing::Availability.run_command(%w[definitely_missing_xyz_123], timeout: 5)
Scout::Testing::Availability.run_command(%w[sleep 30], timeout: 1)
```

### Verbatim output (primitive_probe.log)

```
== provider ==
loaded_feature: /home/mvazque2/git/scout-essentials/lib/scout/testing/availability.rb
Gem::Specification.detect(scout-essentials) => scout-essentials-1.9.1
Gem.loaded_specs['scout-essentials'] => nil
spec.full_gem_path => /home/mvazque2/.rvm/gems/ruby-3.3.1/gems/scout-essentials-1.9.1
file inside installed gem? false (/home/mvazque2/.rvm/gems/ruby-3.3.1/gems/scout-essentials-1.9.1/lib/scout/testing/availability.rb)
Scout::Testing::Availability => Scout::Testing::Availability

== module surface ==
[:executable?, :run_command, :tcp_reachable?]

== executable? ==
executable?('ruby') => true
executable?('definitely_missing_xyz_123') => false

== run_command ok ==
class: Scout::Testing::Availability::CommandResult ([Scout::Testing::Availability::CommandResult(keyword_init: true), Struct, Enumerable, Object])
respond_to?(:members) => true; members=[:argv, :success, :exit_status, :stdout, :stderr, :timed_out, :launch_error]
  ok.success => true
  ok.success? => true
  ok.exit_status => 0
  ok.stdout => ""
  ok.stderr => ""
  ok.timed_out => false
  ok.timed_out? => NO_METHOD
  ok.launch_error => nil
  ok.argv => ["true"]

== run_command launch failure ==
class: Scout::Testing::Availability::CommandResult
  miss.success => false
  miss.exit_status => nil
  miss.stdout => ""
  miss.stderr => ""
  miss.timed_out => false
  miss.launch_error => "Errno::ENOENT: No such file or directory - definitely_missing_xyz_123"

== run_command timeout ==
elapsed: 1.03s
class: Scout::Testing::Availability::CommandResult
  sl.success => false
  sl.exit_status => nil
  sl.stdout => ""
  sl.stderr => "command timed out after 1.0s"
  sl.timed_out => true
  sl.launch_error => nil
```

### Follow-up predicate probe (authoritative for `success?`/`reason`)

The first probe printed `success?` through a rescue clause that mangled the
two failure cases. A clean follow-up
(`tmp/success_predicate_probe.rb`, `ruby tmp/success_predicate_probe.rb`,
exit 0) settles the exact member behavior; verbatim:

```
ok: class=Scout::Testing::Availability::CommandResult
  r.respond_to?(:success?)=true
  r.success=true  r.success?=true
  r.reason=nil
  r.respond_to?(:timed_out?)=false
  r.respond_to?(:reason)=true
miss: class=Scout::Testing::Availability::CommandResult
  r.respond_to?(:success?)=true
  r.success=false  r.success?=false
  r.reason="Errno::ENOENT: No such file or directory - definitely_missing_xyz_123"
  r.respond_to?(:timed_out?)=false
  r.respond_to?(:reason)=true
sleep: class=Scout::Testing::Availability::CommandResult
  r.respond_to?(:success?)=true
  r.success=false  r.success?=false
  r.reason="command timed out"
  r.respond_to?(:timed_out?)=false
  r.respond_to?(:reason)=true
```

### Contract summary for the implementer

Namespace: `Scout::Testing::Availability` (module), require path
`scout/testing/availability`. Public singleton methods (exactly three):
`executable?(name)`, `run_command(argv, timeout: 30)`, `tcp_reachable?`.

- `executable?(name)` -> `true`/`false` (never raises for a missing name;
  a name containing a path separator is checked as a direct file path;
  empty name returns false).
- `run_command(argv, timeout:)` -> always returns a
  `CommandResult` (a `Struct`, `keyword_init: true`) with members, in
  declaration order:
  **`argv, success, exit_status, stdout, stderr, timed_out, launch_error`**.
  - `success` / `success?` - boolean; `success?` is `!!success` (verified
    `true` for the ok case, `false` for launch failure and timeout).
  - `exit_status` - Integer on normal exit, **`nil`** on launch failure and
    on timeout.
  - `stdout` / `stderr` - Strings, bounded (`OUTPUT_LIMIT = 65_536` bytes per
    stream; overflow appends `"\n[output truncated]"`, `TRUNCATION_NOTE`).
  - `timed_out` - boolean; **there is no `timed_out?` predicate**
    (`respond_to?(:timed_out?) => false`).
  - `launch_error` - String like `"Errno::ENOENT: ..."` or `nil`.
  - `CommandResult#reason` - helper (verified) returning `nil` on success,
    else preferring `launch_error`, then `'command timed out'`, then
    `"exit status #{exit_status}"`, then trimmed stderr, then trimmed stdout,
    then `'could not start executable'`.
  - Raises `ArgumentError` only for empty argv or non-positive/non-finite
    timeout (programming errors). Launch failure and timeout are **reported,
    not raised**. Not memoized (documented in source).
- Constants exposed: `DEFAULT_TIMEOUT = 30`, `TCP_TIMEOUT = 5`,
  `OUTPUT_LIMIT = 65_536`, plus internal read/kill constants
  (`READ_CHUNK = 16_384`, `KILL_GRACE = 0.1`, `CHUNK_POLL = 0.05`).
- `run_command` drains both pipes concurrently (`IO.select` loop) and spawns
  the child in its own process group (`pgroup: true`), killing the group
  TERM->KILL on deadline. The struct is declared at
  `lib/scout/testing/availability.rb:25` in the scout-essentials checkout
  (`Struct.new(:argv, :success, :exit_status, :stdout, :stderr, :timed_out, :launch_error, keyword_init: true)`).

Provider resolution caveat (important for steps 7-8): in **this** environment
the file comes from the scout-essentials **git checkout**
(`/home/mvazque2/git/scout-essentials/lib/scout/testing/availability.rb`,
staged-uncommitted there) because `RUBYOPT` includes
`-I /home/mvazque2/git/scout-essentials/lib`. The installed 1.9.1 gem does
**not** contain the file. Any packaging step that assumes
`require 'scout/testing/availability'` works from the released gem will fail
until scout-essentials ships it.

Independent cross-check of the primitive under a real test context is in
`tmp/handoff_probe.rb` (see Handoff digest): 3 tests / 8 assertions, 0
failures, 0 errors, run with `ruby tmp/handoff_probe.rb`.

---

## omit verdict

Probe file `tmp/omit_probe.rb`:

```ruby
require 'test/unit'

class TestOmitProbe < Test::Unit::TestCase
  def test_omit_is_recognized
    omit 'probe'
    flunk 'should not reach here'
  end
end
```

Run: `ruby tmp/omit_probe.rb` -> `OMIT_PROBE_EXIT=0`. Verbatim output:

```
Loaded suite tmp/omit_probe
Started
O
===============================================================================
Omission: probe [test_omit_is_recognized(TestOmitProbe)]
===============================================================================
...(backtrace lines)...
Finished in 0.35 seconds.

1 tests, 0 assertions, 0 pass, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications
0% passed
```

(The `O` progress glyph, the `Omission: probe
[test_omit_is_recognized(TestOmitProbe)]` banner, and the summary counting
the test with `0 pass` while exiting 0 are the essential verbatim markers.)

**Verdict: `omit` is available and recognized.** Test::Unit in play is
**test-unit 3.6.1** (`gem list test-unit` -> `test-unit (3.6.1)`); `omit`
is a built-in Test::Unit assertion, so no extra gem is needed. Crucially
for step 4 (suite gating): **an omitted test does not fail the suite** -
exit status stays 0, matching what the gating step needs (`0 omissions`
counted separately from failures/errors; the run above shows `0% passed`
with exit 0).

---

## Handoff digest

Source: `/home/mvazque2/git/scout-essentials/research/testing-availability-scout-rig-handoff.md`
(read in full, 355 lines; that repo is the read-only reference and was not
modified).

**Scope / layer boundary.** scout-rig owns runtime-availability probes for
interpreters and their packages: `python?`,
`python_modules?`/`python_modules_reason`, `rscript?`,
`r_packages?`/`r_packages_reason` (the two R ones are **reference code only**
- there are no live R call sites in scout-rig today). scout-essentials keeps
only the generic primitives (`executable?`, `run_command`, `tcp_reachable?`).
**Endpoint/model/accelerator probes (`cuda?`, `hf_model_cached?`,
`endpoint_*`, `InfrastructureProbes`) belong to scout-ai, not scout-rig.**

**Corrected reference implementations - probe approach.**

- Python modules probe: fixed probe *source* over **argv**, never
  interpolated names:
  ```python
  import importlib, sys
  missing = []
  for name in sys.argv[1:]:
      try: importlib.import_module(name)
      except Exception as e: missing.append("%s: %s: %s" % (name, type(e).__name__, e))
  if missing:
      sys.stderr.write("; ".join(missing)); sys.exit(1)
  ```
  invoked as `run_command([executable, '-c', probe, *modules], timeout: PROBE_TIMEOUT)`;
  available iff `result.success? && result.exit_status == 0`. The **reason
  comes from stderr** (where tracebacks go), with fallbacks: stderr ->
  `"python exited #{exit_status}"` -> timeout note -> `launch_error`.
- `python?` itself: `[executable, '-c', 'import sys']` and decide on the
  **exit status**, not output.
- R probes: `Rscript --vanilla -e 'cat("ok")'` for existence; packages via a
  fixed probe using **`commandArgs(TRUE)`** with `--args pkg...` (drop the
  retained `"--args"` element), `requireNamespace(p, quietly=TRUE)` per
  package, missing list printed with `cat` to **stdout** (R writes there),
  `quit(status=1)`.

**Defect list (doubles as the test targets for step 3):**

1. `python?` ignored the subprocess exit status (output != working
   interpreter).
2. `python_modules_reason` read **stdout**; import tracebacks go to stderr.
3. memo rescued `Exception` (swallows `SignalException`/`NoMemoryError`) -
   rescue `StandardError` only.
4. `run_bounded` drained stdout before stderr (pipe deadlock), spawned
   outside the rescue (launch failure could escape), and the
   `capture:false` path drained neither pipe. Delegate to
   `Scout::Testing::Availability.run_command` instead.
5. Memoization must key on the **full input set** (executable + env +
   timeout), with an explicit `reset!`.
6. (scout-ai-only, N/A here.)
7. Module names interpolated into Python/R source (quoting escape risk) -
   pass names as argv.

**Memoization discipline.** Memoize each probe keyed on its full inputs
(`(executable, modules/packages, timeout)`), because `SCOUT_TEST_PYTHON` or
`PATH` can change within one process; provide
`ScoutRig::Testing::Availability.reset!` and call it from test setup when the
environment is manipulated; rescue `StandardError`, never `Exception`.

**Interpreter selection.** Suggested order: `ENV['SCOUT_TEST_PYTHON']` wins
(absolute pin for tests); else PATH lookup `python3` then `python`; R:
`ENV['SCOUT_TEST_RSCRIPT']` else `Rscript`. Reliable environment recipe:
put the chosen env's `bin` first on `PATH` so both routes resolve the same
interpreter; **never export `PYTHONHOME`** from test setup (PyCall already
sets it; a foreign one kills subprocesses with "Failed to import encodings").

**Suggested namespace:** `ScoutRig::Testing::Availability` (a scout-rig
test-support module), requiring `scout/testing/availability` and building
the interpreter knowledge on top.

**Constraints carried over:** ordinary unit tests stay offline (probes run
local interpreters only, no network); product-failure assertions must never
become skips (omit only when an optional dependency is genuinely absent);
`rscript?`/`r_packages?` stay unwired until an R integration exists; keep
the layer boundary (no endpoint/model/accelerator probes in scout-rig).

Cross-check probe (`tmp/handoff_probe.rb`, run green: 3 tests, 8 assertions,
0 failures, 0 errors): the argv-based Python probe correctly reports
`torch` missing via stderr (`result.stderr` matches
`/torch: ModuleNotFoundError/`, `success? == false`, `exit_status == 1`),
and `Rscript -e 'cat(...)'`-style probes return success with the value on
stdout - confirming the reference implementations work against the
installed primitive.

---

## Conclusions for the implementer

**Code against these exact names (verified in this environment):**

- `require 'scout/testing/availability'` -> module
  `Scout::Testing::Availability`, singleton methods exactly
  `[:executable?, :run_command, :tcp_reachable?]`.
- `run_command(argv, timeout:)` -> `Scout::Testing::Availability::CommandResult`
  (Struct, `keyword_init: true`), members in declaration order:
  **`[:argv, :success, :exit_status, :stdout, :stderr, :timed_out, :launch_error]`**,
  helper methods `#success?` (`!!success`) and `#reason`. There is **no**
  `timed_out?` predicate - use the `timed_out` field. `exit_status` is `nil`
  on launch failure and on timeout; launch failure and timeout are returned,
  never raised; only empty argv / bad timeout raise `ArgumentError`.
- `executable?(name)` -> boolean, never raises.
- Test::Unit **3.6.1** provides `omit`; omission keeps exit status 0.

**Implementation-shape guidance (from the verified facts):**

- Put scout-rig's probes in `ScoutRig::Testing::Availability`
  (`python?`, `python_modules?(_reason)`, `rscript?`, `r_packages?(_reason)`
  - R reference-only), requiring the primitive and resolving the executable
  as `ENV['SCOUT_TEST_PYTHON']` -> `python3` -> `python` (`SCOUT_TEST_RSCRIPT`
  -> `Rscript`). Today `SCOUT_TEST_*` does not exist anywhere in the repo
  (verified), so the variables are free to define.
- Gate `test_binding` with `omit python_modules_reason(:torch)` (or
  equivalent) - that is the only torch consumer among active tests.
- Delegate every probe launch to `run_command` (which never raises for
  launch failure/timeout); do not rescue `Exception`.
- Remember the two-route interpreter split when writing the gating tests:
  in-process tests follow `PyCall.init`'s `ENV['PYTHON']`-else-PATH choice
  and then **set `ENV['PYTHONHOME']`**, while subprocess tests always run
  literal `python` from PATH. The suite recipe stays "chosen env's `bin`
  first on PATH".

**Divergences from the prior facts (Current state in the delegation):**

1. **HEAD moved**: current HEAD is `386954a` (2026-10-10), not `290ee22`
   (2026-07-31, now 6 commits back). Counts below reflect HEAD+worktree.
2. **Suite size**: the suite runs **23 tests** (15 of them in
   `test/scout/workflow/python/test_task.rb`, 4 of which exist only in the
   uncommitted worktree), not 9. The error count and cause are unchanged
   (1 error, `test_binding`, torch missing).
3. **Working tree is dirty**: 5 modified files (docs, `script.rb`,
   `task.rb`, `test_task.rb`) + 3 stashes. `rake test` above ran against
   that state, not a pristine HEAD.
4. **No second checkout**: `/home/mvazque2/git/scout-rig` does not exist.
5. **Primitive provider**: `gem which` points at the scout-essentials **git
   checkout** (staged, uncommitted there), not an installed gem; the
   installed 1.9.1 gem lacks the file. Step 8 (packaging) cannot assume the
   released gem provides `scout/testing/availability`.
6. **Naming nit**: there is no `test/python/` dir; the script/run/util tests
   live in `test/scout/python/`, and the workflow task tests in
   `test/scout/workflow/python/test_task.rb` (single file).
7. Everything else in the prior facts **held**: torch error attribution,
   literal-`python` subprocess route ignoring `ENV['PYTHON']`, PyCall route
   using `ENV['PYTHON']` else PATH and setting `PYTHONHOME`, no `SCOUT_TEST_*`
   anywhere, `test/scout/test_python.rb` = 11 methods with 10 `_`-disabled,
   no skip logic in any test file.

## Design decisions (post-baseline, step 2)

Delivered step 2: the packaged, opt-in scout-rig availability helper at
`lib/scout-rig/testing/availability.rb`, single documented entry
`require 'scout-rig/testing/availability'`, defining
`ScoutRig::Testing::Availability`. New file only; no tracked file was
edited. The require loads `'scout/testing/availability'` (the
scout-essentials primitive, currently provided by its git checkout) plus
stdlib `socket`; it loads no scout-rig production code, no `ScoutPython`,
no PyCall (`defined?(PyCall)` and `defined?(ScoutPython)` are both nil),
and nothing in the repo requires it back.

### Final API surface (the contract for steps 3-7)

Module-function style (`ScoutRig::Testing::Availability.python_modules?`) and
an optional mixin (`class MyTest; include ScoutRig::Testing::Availability`)
share one implementation and one memo store; every method is an ordinary
instance method and the module `extend self`s. Both call styles exercise the
identical code path (verified: `T.new.check` mixin call returned true).

- `python?(executable: nil, route: :subprocess, timeout: 30)` -> true iff the
  selected Python exists AND a sanity probe (`python -c 'import sys'`) exits 0.
  Decided on exit status, never on output, never on PATH existence alone.
- `python_modules?(*modules, executable: nil, route: :subprocess, timeout: 30)`
  -> true iff every named module imports under the selected interpreter.
  Symbols accepted, normalized to strings. Empty list vacuously true.
- `python_modules_reason(*modules, executable: nil, route: :subprocess, timeout: 30)`
  -> nil on success, else one concise diagnostic naming the resolved
  executable path, the failing module name(s) and the stderr tail.
- `rscript?(executable: nil, timeout: 30)` and
  `r_packages?(*packages, executable: nil, timeout: 30)` /
  `r_packages_reason(*packages, executable: nil, timeout: 30)` -> same shape
  for R; availability means requireNamespace LOADS. Reasons are built
  stdout-first (the probe's missing list), then stderr tail. Reference probes
  only: scout-rig has no R execution runtime, and these helpers claim none.
- `embedded_python` / `subprocess_python` -> the interpreter each route WOULD
  use, computed without initializing the bridge.
- `python_route_divergence` -> nil when both routes resolve to the same
  interpreter, else a one-line message naming both.
- `reset!` -> clears the memo store; returns nil.
- Constants: `DEFAULT_TIMEOUT = 30`, `DEFAULT_ROUTE = :subprocess`,
  `ROUTES = [:subprocess, :embedded]`, `REASON_TAIL = 400`, `MEMO`,
  `MEMO_MUTEX`, plus the four frozen probe-source constants.

### Selection precedence (Python; implemented exactly)

`executable:` kwarg > `ENV['SCOUT_TEST_PYTHON']` > route default. Route
default for `route: :subprocess` (the default) is `subprocess_python` = the
literal `python` from PATH (what `ScoutPython.script/run_file/python_task`
spawn); for `route: :embedded` it is `embedded_python` = `ENV['PYTHON']`
when set (blank counts as unset), else first of `python3`/`python` on PATH.
R: `executable:` > `ENV['SCOUT_TEST_RSCRIPT']` > `Rscript` from PATH.

`SCOUT_TEST_*` versus `PYTHON`/`PATH` (in code comments near `python_target`):
`PYTHON` and `PATH` are PRODUCTION inputs this module never mutates;
`SCOUT_TEST_PYTHON`/`SCOUT_TEST_RSCRIPT` are TEST-ONLY pins that override
route resolution for probing only. A pin applies to whichever route is
probed (so a pinned probe cannot detect a divergence - by design;
`python_route_divergence` ignores pins precisely so a pin cannot hide a real
production divergence). The pins do not change production code. Verified
behavior: with `SCOUT_TEST_PYTHON=/nonexistent/python-wrapper`,
`python?` is false and the reason names the wrapper and the launch error.

### Probe process discipline

- Both Python probes go through
  `Scout::Testing::Availability.run_command(argv, timeout:)`; the bounded
  runner is scout-essentials', never re-implemented here. Launch failure and
  timeout are reported on the CommandResult and converted to a reason, so the
  boolean helpers can never leak an exception from an unavailable
  interpreter.
- Python module probe is a frozen `PYTHON_MODULES_PROBE` literal passed via
  `-c`, iterating `sys.argv[1:]` with `importlib.import_module`; missing
  modules are written to stderr as `name: ExceptionType: message` and any
  miss exits 1. R probe is a frozen `R_PACKAGES_PROBE` literal passed via
  `Rscript --vanilla -e <src> --args <names>`, reading
  `commandArgs(TRUE)` (filtering `--args`), calling `requireNamespace` per
  package, `cat`ing the missing list to stdout and `quit(status=1)` on a
  miss. Names never touch the source of either probe, so no module or
  package name can break out of a literal.
- The file contains zero `rescue` clauses at all (the grep below shows no
  `rescue Exception`, `Open3`, `popen` or `fork`), which is the strictest
  reading of "rescue StandardError only": unexpected exceptions propagate
  and are never cached as "unavailable".
- Reasons preserve a bounded tail (`REASON_TAIL = 400` chars) of the
  relevant stream: stderr for Python (where tracebacks live), stdout first
  then stderr for R.

### Timeout defaults

`DEFAULT_TIMEOUT = 30`, aligned with the primitive's
`Scout::Testing::Availability::DEFAULT_TIMEOUT`; every helper takes an
explicit `timeout:` kwarg, and every timeout reason says "raise the
timeout: keyword" so slow imports (numpy, pandas, torch) are cheap to
accommodate. Timeout is part of the memo key, so raising it never replays a
stale verdict.

### Memoization key design and reset!

Keys are `[kind, resolved_executable_path, sorted_names, timeout, route]`
(route present on Python probes). The executable component is the CANONICAL
absolute realpath, recomputed on every call through the current
`SCOUT_TEST_*`/`PYTHON`/`PATH`, so a mid-process environment change yields a
new key and re-probes naturally; `reset!` (MEMO_MUTEX-guarded `MEMO.clear`)
is the explicit hygiene hook for tests that mutate the environment. Only
definitive results are stored (nil or a reason String); the lock is held
across the probe so concurrent test threads cannot spawn duplicate children
for one key. The store lives in constants (`MEMO`, `MEMO_MUTEX`) rather than
module ivars so the mixin and module-function styles share one cache.

### embedded-is-prediction-not-validation boundary

`embedded_python` mirrors the documented bridge choice (`ENV['PYTHON']` else
python3/python on PATH; candidate order read from the pycall gem since the
user docs do not spell it out - ScoutCoder note left in the source). It does
not run the interpreter, does not touch `ENV` (the real init exports
`PYTHONHOME`), and cannot prove the native library loads into the Ruby
process. Probing `route: :embedded` therefore validates the predicted
interpreter as a subprocess, never the in-process binding;
`python_route_divergence` likewise compares PREDICTED selections only, and
no helper claims that one probe validates both routes.

### Deviations from the delegation brief

1. **Handoff's resolution order, not used verbatim**: the handoff sketched
   `ENV['SCOUT_TEST_PYTHON'] -> python3 -> python` as the (single) resolution
   chain. The brief's own precedence plus the two-route reality make that
   ambiguous, so routes were made explicit: the pin sits between the explicit
   kwarg and the route default, and the route defaults differ (:subprocess ->
   literal `python`; :embedded -> PYTHON else python3/python). This is what
   "explicit executable > pin > route default" means operationally.
2. **No `timed_out?` predicate assumed** (baseline fact); timeouts are read
   from the CommandResult's `timed_out` member, as delivered.
3. **R sanity probe prints "ok"** rather than nothing, so a broken Rscript is
   distinguishable from a silently-absent one in reasons; the verdict is
   still the exit status, not the output.
4. Nothing else deviates: single lib file (no second file was cleaner),
   new files only, no network/installs/gem operations, no PyCall
   initialization anywhere, no name interpolation into probe source, and the
   runner was never duplicated.

### Smoke checks recorded verbatim (repo root, ruby 3.3.1)

1. python_modules probe:
   `ruby -Ilib -e "require 'scout-rig/testing/availability'; puts defined?(PyCall).inspect; puts ScoutRig::Testing::Availability.python_modules_reason('sys').inspect; puts ScoutRig::Testing::Availability.python_modules?('sys').inspect; puts ScoutRig::Testing::Availability.python_modules_reason('no_such_module_xyz').inspect; puts ScoutRig::Testing::Availability.python_modules?('no_such_module_xyz').inspect"`
   ```
   nil
   nil
   true
   "/usr/bin/python3.13: missing Python modules: no_such_module_xyz (no_such_module_xyz: ModuleNotFoundError: No module named 'no_such_module_xyz')"
   false
   ```
2. route accessors and divergence:
   `ruby -Ilib -e "require 'scout-rig/testing/availability'; a=ScoutRig::Testing::Availability; puts a.embedded_python.inspect; puts a.subprocess_python.inspect; puts a.python_route_divergence.inspect"`
   ```
   "python3"
   "python"
   nil
   ```
   In this environment `python3` and `python` both realpath to
   `/usr/bin/python3.13`, so the routes agree and the reporter returns nil.
3. R probes (R IS present here, /usr/lib/R/bin/Rscript, base loads):
   `ruby -Ilib -e "require 'scout-rig/testing/availability'; puts ScoutRig::Testing::Availability.rscript?.inspect; puts ScoutRig::Testing::Availability.r_packages_reason('base').inspect"`
   ```
   true
   nil
   ```
4. grep of the delivered file (only hit is a comment mentioning PyCall.init's
   documented ENV['PYTHON'] behavior; no `rescue Exception`, `Open3`,
   `popen`, `fork`):
   ```
   $ grep -n "PyCall\|rescue Exception\|Open3\|popen\|fork" lib/scout-rig/testing/availability.rb
   220:      # PyCall.init reads ENV['PYTHON'] and otherwise investigates python3
   ```
5. isolation (require leaves ScoutPython, PyCall undefined; `Scout` is the
   primitive's own `Scout::Testing` namespace, unavoidable and intentional):
   ```
   ruby -Ilib -e "require 'scout-rig/testing/availability'; puts defined?(ScoutPython).inspect; puts defined?(PyCall).inspect; puts defined?(Scout).inspect"
   nil
   nil
   "constant"
   ```
6. extra validation beyond the brief: mixin call style returns true for
   `python_modules?('sys')`; symbol args work (`r_packages?(:base)` -> true);
   multi-module probe with a miss (`python_modules?('no_such_module_abc',
   'sys')` -> false, reason names only the missing one); with
   `SCOUT_TEST_PYTHON=/nonexistent/python-wrapper` after `reset!`,
   `python?` -> false and the reason carries the launch error;
   `r_packages?('nosuchpkgxyz123')` -> false with reason
   `"/usr/lib/R/bin/Rscript: missing R packages: nosuchpkgxyz123"`;
   `ENV['PYTHON']='/tmp/other_python'` (unresolvable) makes
   `python_route_divergence` name both sides; clearing PATH makes
   `subprocess_python` nil and the divergence message say the subprocess
   route cannot run.

### Layer boundary reminder for later steps

No endpoint/model/accelerator probes here - those belong to scout-ai (see
the scout-essentials handoff). Step 8 (packaging) must remember that the
released scout-essentials gem (1.9.1) does NOT yet ship
`scout/testing/availability`; only its git checkout does.

---

## Step-1 re-verification addendum (independent second pass, 2026-10-11)

Every load-bearing fact above was re-derived in a fresh pass over the same
tree rather than trusted. One clarification and one required section
(open questions and risks) are added here; nothing above was rewritten.

Re-verified, unchanged:

- `git rev-parse HEAD` -> `386954a463d8e1a4d335d366836af3cc8c68c584`;
  `git status --short` still shows the same 5 modified files and the
  untracked `lib/scout-rig/` + this note; `VERSION` -> `0.2.6`.
- Fresh `rake test` (raw log `/tmp/rig_baseline_rake_test.log`):
  `23 tests, 83 assertions, 0 failures, 1 errors, 0 pendings, 0 omissions,
  0 notifications`, `exit=1` (rake aborts on the loader's non-zero status).
  Sole error unchanged: `Error: test_binding(TestPython): PyCall::PyError:
  <class 'ModuleNotFoundError'>: No module named 'torch'` raised from
  `test/scout/test_python.rb:113` (`pyimport :torch`). Classification:
  **environmental** (optional package absent; torch is not declared in the
  gemspec or `python/pyproject.toml`, which requires only pandas). Zero
  code failures.
- `python3 --version` / `python --version` -> Python 3.13.3;
  `which python python3` -> `/usr/bin/python` / `/usr/bin/python3`;
  `python3 -c 'import torch'` -> ModuleNotFoundError, exit 1.
- Selection facts re-grepped at the same line numbers: embedded route
  `lib/scout/python.rb:15` calls `PyCall.init` with no argument (pycall's
  `init.rb:24` supplies `python = ENV['PYTHON']`, `LibPython::Finder`
  `DEFAULT_PYTHON = ['python3','python']`, `finder.rb:46-51` exports
  `ENV['PYTHONHOME']`); subprocess route spawns literal `python` from PATH
  at `lib/scout/python/script.rb:105` (`ScoutPython.script`) and
  `script.rb:113-122` (`ScoutPython.run_file`), consumed by
  `lib/scout/workflow/python/task.rb:33/45/153`. `ENV['PYTHON']` has zero
  hits in scout-rig's own `lib/`. `SCOUT_TEST_` still appears only in the
  step-2 file `lib/scout-rig/testing/availability.rb` and in this note.
- Primitive contract re-probed in a fresh process:
  members `[:argv, :success, :exit_status, :stdout, :stderr, :timed_out,
  :launch_error]`; singleton methods `[:executable?, :run_command,
  :tcp_reachable?]`; `success?` and `reason` exist, `timed_out?` does NOT
  (`CommandResult.instance_methods(false).include?(:timed_out?) => false`).
  Newly pinned exact raise messages and reason strings:
  `run_command([], timeout: 5)` -> `ArgumentError "argv must not be empty"`;
  `run_command(%w[true], timeout: 0)` -> `ArgumentError "timeout must be
  positive and finite"`; exit-1 child -> `success=false, exit_status=1,
  reason="exit status 1"`; missing executable -> `exit_status=nil,
  reason="Errno::ENOENT: No such file or directory - ..."`; timeout ->
  `timed_out=true, exit_status=nil, reason="command timed out"`. The
  require itself succeeded (no blocker).
- Provider still the checkout: `$LOADED_FEATURES` resolves
  `/home/mvazque2/git/scout-essentials/lib/scout/testing/availability.rb`
  (via `RUBYOPT -I`), while `Gem::Specification.find_by_name` reports
  scout-essentials **1.9.1** at
  `/home/mvazque2/.rvm/gems/ruby-3.3.1/gems/scout-essentials-1.9.1`.

### Clarification on the omit probe command

The delegation's literal probe
(`Test::Unit::TestCase.instance_methods(false).map(&:to_s).grep(/omit/)`)
returns `[]` and would be misread as "omit unavailable". `omit`,
`omit_if` and `omit_unless` are **not defined directly on
`Test::Unit::TestCase`**: they are mixed in, and
`Test::Unit::TestCase.instance_method(:omit).owner` is
`Test::Unit::TestCaseOmissionSupport` (test-unit 3.6.1). The verdict above
stands (omission works and keeps exit status 0); the correct introspection
is `Test::Unit::TestCase.method_defined?(:omit)` (true) or an actual
omitting test.

### Open questions and risks

1. **Packaging risk (highest).** The released scout-essentials 1.9.1 gem
   does **not** ship `lib/scout/testing/availability.rb`; only the git
   checkout does, where the file is still staged-uncommitted. Any
   environment resolving the gem instead of the checkout will fail the
   require. Step 8 must not assume the released gem provides it.
2. **Dirty-tree risk.** The baseline ran against HEAD+worktree: 5 modified
   tracked files plus the untracked step-2 deliverable and this note. The
   23-test count includes 4 tests that exist only in the worktree copy of
   `test/scout/workflow/python/test_task.rb`; a pristine-HEAD checkout runs
   19. Later steps must state which baseline they code against.
3. **PYTHONHOME poisoning.** Any in-process `PyCall.init` exports
   `ENV['PYTHONHOME']` for the whole Ruby process (pycall
   `libpython/finder.rb:46-51`). Test setup must never export PYTHONHOME,
   and mixed-route runs (embedded then subprocess in one process) can break
   the subprocess interpreter with "Failed to import encodings".
4. **Two-route interpreter split.** Subprocess = literal `python` from PATH;
   embedded = `ENV['PYTHON']` else `python3`/`python`. They coincide here
   (both `/usr/bin/python3.13`) but that is environmental luck, not a
   guarantee; the recommended recipe stays "chosen env's bin first on PATH".
5. **No `timed_out?` predicate.** Code assuming one raises NoMethodError;
   read the `timed_out` member (and `reason` for the human string).
6. **Red stock run.** `rake test` exits 1 whenever any test errors, so until
   step 4 gates `test_binding` on torch availability the stock suite stays
   red in torch-less environments. Gating must convert this to an omission,
   not to a skip that hides genuine failures.
7. **Gemspec staleness.** 27 tracked files are missing from the gemspec file
   list (all of `doc/`, all `research/*.md`, `python/scout/task_errors.py`,
   `.gitignore`) and 2 listed files no longer exist
   (`doc/Python.md`, `doc/PythonWorkflow.md`). Regenerating via
   `rake gemspec` was deliberately not run.
8. **R stays reference-only.** No R runtime is exercised by the suite;
   `rscript?`/`r_packages?` must remain unwired to unit tests until an R
   integration exists.
9. **Agent-tooling observation (not a repo defect).** In this environment,
   files created under `tmp/` via the Workspace `write` task were not
   subsequently visible to `bash`/`list_directory` exec calls, while
   bash-created files were visible to the read tasks. Scratch probes that
   must be executed by the exec tasks should be created with bash heredocs.

## Step 2 design decisions

Implemented `lib/scout-rig/testing/availability.rb` (this file is untracked
alongside the rest of `lib/scout-rig/`, which was already untracked before
step 2; no tracked file was touched by this step).

### Adapt-vs-replace decision

**Replace.** The pre-existing untracked draft at
`lib/scout-rig/testing/availability.rb` (24228 bytes, provenance unknown,
mtime 2026-10-11 00:53) was read in full and compared against the
scout-essentials handoff's corrected reference implementations and defect
list. It was substantively unsound: it committed the handoff's failure
modes. Concretely, the draft:

- built its reason strings from `stdout` first (the handoff's
  "stdout-based reasons" defect), instead of stderr-first for Python and
  stdout-first-only-for-R;
- used a plain `rescue => e` in one place that the handoff flags as too
  broad for signal hygiene in the specific spots the draft used it;
- cached its probe results keyed on the *requested* module names with the
  timeout baked into the key but NOT keyed on the *resolved* executable
  identity (no symlink canonicalization, so `python3` and `python`
  aliasing one binary produced two cache entries while a PATH change
  mid-process could serve a stale verdict);
- left the embedded-route prediction as "the interpreter from ENV['PYTHON']
  or PATH" without ever defining what PATH order it would use, and
  documented `python_routes_divergence_reason` as validating both routes.

The rewrite keeps the draft's one good idea — routing all launches through
`Scout::Testing::Availability.run_command` — and discards everything else.
The final file is a full rewrite, not a patch of the draft.

Provenance caveat: the draft was read in full once, before being replaced
by this rewrite; it no longer exists anywhere in the tree, so the defect
observations above are as-observed from that single read and cannot be
re-verified from the working copy. The replace decision, not the itemized
defect list, is what this note guarantees: nothing of the draft survives
except the choice to launch through the scout-essentials primitive, which
the rewrite would have made independently.

### Namespace / require rationale

`ScoutRig::Testing::Availability` in
`lib/scout-rig/testing/availability.rb`. `require
'scout-rig/testing/availability'` loads only
`scout/testing/availability` (the scout-essentials primitive) plus stdlib
`socket` transitively. It does NOT load `scout-rig.rb`, `scout/python.rb`,
or PyCall, verified: `defined?(PyCall)` is nil, `defined?(ScoutPython)` is
nil, and `$LOADED_FEATURES` contains neither `scout/python.rb` nor
`scout-rig.rb` after require in a fresh process. No production file
requires it back, so it remains strictly opt-in for test suites.

### Selection precedence (Python)

1. `executable:` keyword (explicit; overrides everything, including pins)
2. `ENV['SCOUT_TEST_PYTHON']` (test-only pin)
3. route default — `:subprocess` (default) → `subprocess_python` (the
   literal `python` from PATH, matching `lib/scout/python/script.rb`'s
   `CMD.cmd(... "python" ...)` spawn); `:embedded` → `embedded_python`
   (`ENV['PYTHON']` if set, else first of `python3`, `python` found on
   PATH, mirroring `PyCall.init`/`LibPython::Finder::DEFAULT_PYTHON`)

R: `executable:` → `ENV['SCOUT_TEST_RSCRIPT']` → `Rscript` from PATH.

`SCOUT_TEST_PYTHON` deliberately does not affect
`python_routes_divergence_reason`, `embedded_python`, or
`subprocess_python`: a pinned probe that silently hid a real production
divergence is exactly what the divergence reporter exists to expose.

### Cache-key definition

`[probe_kind, resolved_executable_identity, sorted_names, timeout, route]`
where `resolved_executable_identity` is `File.realpath` of the resolved
candidate (name → first PATH hit → symlink-canonicalized absolute path, or
the raw name when unresolvable) so aliasing interpreters collapse to one
entry and a PATH change mid-process re-resolves and produces a fresh key.

Only definitive outcomes are memoized (success / missing module / missing
package — anything where the child reached an exit status). A timeout or a
launch error is never memoized; an identical later call re-runs. The
primitive's own contract is the authority here: `run_command` never
memoizes on its side either.

### Defaults chosen

- `DEFAULT_TIMEOUT = 30` seconds, aligned with
  `Scout::Testing::Availability::DEFAULT_TIMEOUT`. Rationale: importing
  numpy/pandas/torch cold is slower than a stdlib import, and 30 s is
  comfortably above interpreter start time on this host (probe overhead
  observed ~0.5 s) without making a genuinely-hung interpreter painful in
  a test run. Overridable per call via `timeout:`.
- `DEFAULT_ROUTE = :subprocess` for all Python probe helpers, because the
  subprocess route is what `ScoutPython.script` / `run_file` /
  `python_task` actually spawn today.
- `REASON_TAIL = 400` chars of captured output kept in a reason string.
- Probe argv layout: `[exe, '-c', SOURCE, *names]` for Python (verified:
  everything after `-c <source>` lands in `sys.argv` verbatim, even names
  like `-c` or `--version`; none of those are re-parsed as interpreter
  options when they arrive in trailing position). R:
  `[exe, '--vanilla', '-e', SOURCE, '--args', *names]`, with the probe
  filtering the literal `'--args'` element that `commandArgs(TRUE)`
  retains.

### Deviations from the spec

1. `python_modules_reason` on a *missing module* under a broken
   interpreter cannot name the resolved executable and the module list
   both cleanly when the interpreter itself is the failure; the reason
   string keeps both (executable first, then the tail) rather than
   dropping either. No behavior change, just reason-string shape.
2. The spec's example name for the divergence helper was
   `python_routes_divergence_reason`; the implemented name is exactly
   that, and no shorter alias (`python_route_divergence_reason`) exists.
3. The memoization mutex is held across the child launch (so concurrent
   test threads don't duplicate work for one key). This serializes probes
   in threaded test suites, which is a performance choice, not a
   correctness one; the alternative (double-checked locking) was
   considered and rejected as unnecessary complexity for this consumer.
4. `reset!` returns nil and there is no `reset?` predicate — the spec
   named no return contract, and nil keeps it a hygiene hook, not a query.
5. Deviation flagged for honesty, not behavior: the itemized defects of
   the replaced draft (see the provenance caveat above) were recorded from
   a single read and cannot be re-verified, because the rewrite replaced
   the file in place. The replace-vs-adapt decision does not depend on the
   itemization being exhaustive — the draft also simply lacked the
   route-aware resolution (`embedded_python`/`subprocess_python`/divergence
   diagnostic), the `SCOUT_TEST_PYTHON`/`SCOUT_TEST_RSCRIPT` pin precedence,
   and the R-side probes that this step's spec required, so even a
   defect-free draft would have needed the same structural rewrite.
6. `python_routes_divergence_reason` reports a divergence when EITHER route
   fails to resolve (including "neither resolves"), not only when both
   resolve to different interpreters. A silent nil for "both broken" would
   read as agreement to a test that never runs the probe, which is worse
   than the noise.

## Step 3 test evidence

- File: `test/scout-rig/testing/test_availability.rb` (30 tests, 121
  assertions in a normal environment).
- Standalone run, normal environment
  (`ruby -Ilib -Itest test/scout-rig/testing/test_availability.rb`):

      30 tests, 121 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications
      100% passed

- Hostile no-python/no-R environment (PATH restricted to a scratch dir
  holding only `ruby sh bash gcc cc make as ld ar cat sleep uname`; ruby
  itself still resolves because `RUBYOPT` and the gem paths stay untouched
  and the harness only needs the toolchain for the RubyInline build that
  `test_helper.rb`'s `require 'scout'` triggers once):

      30 tests, 113 assertions, 0 failures, 0 errors, 0 pendings, 2 omissions, 0 notifications
      100% passed

  The two omissions are exactly the real-interpreter-gated tests below;
  everything else passes on fakes alone.

- Harness discovery (`rake test`, which globs `test/**/test_*.rb` through
  the juwelier/rake test loader and therefore picks the new file up with
  no Rakefile change):

      53 tests, 204 assertions, 0 failures, 1 errors, 0 pendings, 0 omissions, 0 notifications

  23 -> 53 tests (30 new). The 1 error is the pre-existing,
  unrelated `TestPython#test_binding` torch error already documented in
  the Step 1 baseline (`ModuleNotFoundError: No module named 'torch'`);
  the new file contributes 0 failures and 0 errors to the harness run.

- Real-interpreter-gated tests (the only `omit`s in the file):
  - `test_python_modules_real_stdlib_gated` — needs a real python to import
    the real stdlib `sys`; omits with "no python interpreter available".
  - `test_r_packages_real_runtime_gated` — needs a real Rscript to prove
    `r_packages?` answers for a genuinely present package (`base`); omits
    with "no Rscript available".
  Both gates probe with the default route, so they also verify the
  default-route plumbing whenever a real interpreter exists.

- Helper-code changes made during this step: **none**. Every failure during
  test-driven refinement was an over-strict or wrongly-assumed test
  expectation, fixed in the test file only:
  - `subprocess_python` in a PATH without `python` returns nil (it mirrors
    the production route's literal `python`), so the resolution test now
    asserts nil there and a new test covers the `python`-present case.
  - `defined?(PyCall)` returns nil (not the string "nil"), so the isolated
    probe serializes `nil` explicitly before JSON.
  - The isolated-probe helper needed the repo `lib/` derived from `__dir__`
    (three levels up) plus the scout-essentials checkout on the load path,
    with `RUBYOPT` cleared so the ambient 22-entry `-I` stack does not make
    the isolation assertion vacuous.

## Step 4 gating audit

Table 1 — every test file under `test/` (counts are methods, not assertions).
"Route" is the interpreter route the running tests actually exercise.
"Gate" is what this step did.

| file | running | `_`-disabled (pre-existing) | optional prereq (route) | required deps | gate decision |
|---|---|---|---|---|---|
| `test/scout/test_python.rb` | 1 (`test_binding`) | 9 (`_test_python`, `_test_run_log`, `_test_keras`, `_test_keras_import`, `_test_iterate`, `_test_lambda`, `_test_import_method`, `_test_class_new_obj`, `_test_single`, `_test_threaded`) | `torch` (:embedded — `pyimport :torch` runs IN-PROCESS through `ScoutPython.binding_run`/PyCall, so the interpreter that must have it is the one PyCall init selects) | none (torch required by no `lib/` code and no manifest; `python/pyproject.toml` needs only pandas) | **GATE** `test_binding` with `omit` + `python_modules?` :embedded. The 9 disabled tests stay disabled (out of scope this pass); apparent prereqs: torch/keras, plain stdlib, PyCall lambda eval — none re-enabled. |
| `test/scout/python/test_script.rb` | 4 (`test_script`, `test_script_tsv`, `test_script_tsv_save`, `test_script_exception`) | 0 | pandas/scout-py via `import scout` in the child script (:subprocess — `ScoutPython.script` spawns literal `python`), but `import scout` is scout-rig's OWN packaged Python code → treated as REQUIRED, not gateable-by-package-probe | `scout` python package (own code); pandas (manifest dep of the python package, which the manifest requires for the tested `scout.tsv` path) | **NO GATE.** A missing `scout` import there is a packaging/path failure worth failing loudly. pandas is part of the packaged package's manifest → same verdict (required). All 4 pass here today. |
| `test/scout/python/test_util.rb` | 2 (`test_tuple`, `test_numpy`) | 0 | `numpy` (:embedded — `ScoutPython.run :numpy` and `tsv2df` run in-process via PyCall) | numpy is required by no `lib/` code and no manifest → optional test prerequisite | **GATE** both, embedded route, reason names numpy. |
| `test/scout/python/test_run.rb` | 0 | 1 (`__test_run_threaded`) | (n/a — not running) | n/a | **NO GATE** (nothing runs; file contributes 0 tests). Pre-existing disabled, prereq: plain stdlib + threaded PyCall. |
| `test/scout/workflow/test_python.rb` | 1 (`test_file`) | 0 | `import scout` in the task file (:subprocess — `python_task` runs the file in a child process) | `scout` python package = own packaged code → REQUIRED | **NO GATE.** Packaging failure must fail loudly. Passes here today. |
| `test/scout/workflow/python/test_task.rb` | 15 | 0 | `import scout` in generated task files and `python/pyproject.toml`-style packaging (:subprocess for `run_file`/`load_directory` metadata collection; two tests stub `ScoutPython.run_file` and never launch python) | `scout` python package = own packaged code → REQUIRED | **NO GATE.** Passes here today; stubbed tests need nothing. |
| `test/scout-rig/testing/test_availability.rb` | 30 | 0 | none (fakes only; 2 omit-gated on a REAL interpreter, added deliberately in step 3) | scout-essentials `scout/testing/availability` (required, asserted in-file) | **NO GATE** (out of scope this step, untouched). |
| `test/test_helper.rb` | — (harness, 0 tests) | — | — | — | **ADD ONE `require 'scout-rig/testing/availability'`** so every test file gets the helpers without per-file requires; test-only file, not a production entry point, so the opt-in rule holds. |

Golden rule restated for the edits: the probe governs OMITTION ONLY. The gate
sits at the top of the test method, and the `pyimport`/`ScoutPython.run` under
test still executes unconditionally whenever the probe passed — so a passing
probe can never mask a PyCall/native-binding failure.

## Step 4 evidence

- Audit: see "Step 4 gating audit" above (written BEFORE any test edit).
- Files edited (3, all ours; the 5 not-ours files untouched):
  - `test/test_helper.rb` — one require added after `require 'scout'`:
        # Test-only availability probes (scout-rig testing support). Loaded here so
        # every test file can gate optional prerequisites with omit; NOT required by
        # any production entry point.
        require 'scout-rig/testing/availability'
  - `test/scout/test_python.rb` — gate at the top of `test_binding` (route
    `:embedded`), body unchanged and unconditional after it:
        omit(
          "torch not importable in the embedded (PyCall) interpreter: #{ScoutRig::Testing::Availability.python_modules_reason('torch', route: :embedded)}. " \
          'Install torch or pin SCOUT_TEST_PYTHON to an interpreter that has it.'
        ) unless ScoutRig::Testing::Availability.python_modules?('torch', route: :embedded)
  - `test/scout/python/test_util.rb` — same shape for `test_tuple` and
    `test_numpy`, naming `numpy` instead of torch (numpy is the actual
    in-process dependency of `tsv2df`/`df2tsv` and `ScoutPython.run :numpy`).
- `test/scout-rig/testing/test_availability.rb`: untouched (still 30/121).

- `rake test` BEFORE this step (recorded in step 3, torch-less machine):

      53 tests, 204 assertions, 0 failures, 1 errors, 0 pendings, 0 omissions, 0 notifications

- `rake test` AFTER this step (verbatim; exit 0):

      53 tests, 204 assertions, 0 failures, 0 errors, 0 pendings, 1 omissions, 0 notifications

  1 error -> 0 errors, 1 omission: the torch-less environment now omits
  `test_binding` with a reason naming torch, the embedded interpreter and the
  remedy. numpy is present here, so `test_util.rb` runs both tests (no
  omission on this machine; the gate fires only where numpy is missing).

- Touched files standalone (verbatim summaries):
  - `test/scout/test_python.rb`: `1 tests, 0 assertions, 0 failures, 0 errors, 0 pendings, 1 omissions, 0 notifications`
  - `test/scout/python/test_util.rb`: `2 tests, 2 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications`
  - `test/test_helper.rb` change verified by every standalone run above
    loading the helpers through it.
  - Untouched files re-run to confirm no collateral change:
    `test/scout/python/test_script.rb` 4/6/0/0, `test/scout/workflow/test_python.rb` 1/1/0/0,
    `test/scout/workflow/python/test_task.rb` 15/74/0/0, `test/scout-rig/testing/test_availability.rb` 30/121/0/0.

- Omission text observed in the suite (verbatim):
      Omission: torch not importable in the embedded (PyCall) interpreter: /usr/bin/python3.13: missing Python modules: torch (torch: ModuleNotFoundError: No module named 'torch'). Install torch or pin SCOUT_TEST_PYTHON to an interpreter that has it. [test_binding(TestPython)]

- Golden-rule check (throwaway, `/tmp/golden_pre.rb`, NOT committed):
  pre-loaded a stub that makes `ScoutRig::Testing::Availability.python_modules?`
  return true and `python_modules_reason` return nil (i.e. a probe that lies
  "torch is importable"), then ran the real
  `test/scout/test_python.rb --name test_binding`:

      ruby -Ilib -Itest -r/tmp/golden_pre.rb test/scout/test_python.rb --name test_binding
      Error: test_binding(TestPython): PyCall::PyError: <class 'ModuleNotFoundError'>: No module named 'torch'
      /home/mvazque2/.rvm/gems/ruby-3.3.1/gems/pycall-1.5.2/lib/pycall/import.rb:18:in `pyimport'
        => 123:       pyimport :torch
      1 tests, 0 assertions, 0 failures, 1 errors, 0 pendings, 0 omissions, 0 notifications

  Interpretation: with the gate satisfied (probe true) the omission does NOT
  fire and the unconditional `pyimport :torch` inside the body raises the real
  PyCall::PyError — the gate cannot mask a present-but-failing interpreter or
  binding. Conversely, with the real probe on this machine the gate fires
  BEFORE any PyCall call, so no spurious error occurs.

## Step 5 documentation evidence

Files edited (4, all in the allowed set; no other doc touched):

- `doc/user/TestingAndPackaging.md` — primary target. Suite-state refresh
  (layout tree, 9 -> 53 tests, per-file prereq table now including the
  availability test file), rewritten "What rake test does today" (omission,
  not error, with the verbatim omission text), new "Optional-prerequisite
  gating with the availability helpers" section carrying the full API table,
  result meanings, selection precedence, route semantics + divergence +
  recommended practice, probe-vs-PyCall-validation distinction, the gate
  pattern, and the gating recipe; footer updated to
  "Verified against HEAD `386954a4`".
- `README.md` — development/testing section rewritten: the suite now reports
  an honest omission instead of erroring; short require path + one gating
  example; pointer to the full page.
- `doc/user/PythonEnvironments.md` — one tight addition after the PyCall
  selection paragraph: the subprocess route's independent selection, the
  `PYTHONHOME` side effect, `python_routes_divergence_reason` as the
  reporter, and the bin-first-on-PATH remedy, cross-linking
  TestingAndPackaging.md.
- `doc/developer/Architecture.md` — External (Python packages) entry for
  `torch` updated: optional test prerequisite gated via the availability
  helpers; numpy likewise; neither required by production code.

API table as committed (extracted verbatim from the file after editing):

| Method | Returns |
|---|---|
| `python?(executable: nil, route: :subprocess, timeout: nil)` | `true` iff the selected Python exists **and runs** (a sanity probe must exit 0); `false` otherwise. PATH existence alone is not enough. |
| `python_modules?(*modules, executable: nil, route: :subprocess, timeout: nil)` | `true` iff every named module imports in the selected interpreter. An empty list is vacuously true **once an interpreter was resolved**. |
| `python_modules_reason(*modules, ...)` | `nil` on success; otherwise one concise string: the resolved executable path, the missing/unloadable module names, and the condensed exception text from stderr. |
| `rscript?(executable: nil, timeout: nil)` | `true` iff the selected Rscript exists and runs (sanity probe exits 0). |
| `r_packages?(*packages, executable: nil, timeout: nil)` | `true` iff every named package **loads** (`requireNamespace`), not merely appears in an installation list. |
| `r_packages_reason(*packages, ...)` | `nil` on success; otherwise the resolved executable path, the missing package names (stdout first), then the stderr tail. |
| `embedded_python` | The interpreter the embedded route **would** use, without running anything: `ENV['PYTHON']` if set, else the first `python3`/`python` on PATH. `nil` when neither exists. |
| `subprocess_python` | The interpreter the subprocess route uses: the literal command `python` from PATH (`ENV['PYTHON']` is never consulted there). `nil` when PATH has no `python`. |
| `python_routes_divergence_reason` | `nil` when both routes resolve to the same interpreter (symlinks canonicalized); otherwise one sentence naming both resolutions, the `ENV['PYTHON']`/PATH cause, and that no probe validates both routes. |
| `reset!` | Clears all memoized probe results (returns `nil`). |

Scope check, `git diff --stat` after the edits:

     README.md                                |  19 +++-
     doc/developer/Architecture.md            |  10 +-
     doc/developer/PythonWorkflowInternals.md |  10 ++
     doc/user/DefiningPythonTasks.md          |  25 +++++
     doc/user/PythonEnvironments.md           |  20 ++++
     doc/user/TestingAndPackaging.md          | 189 +++++++++++++++++++++++++-----
     lib/scout/python/script.rb               |  13 ++-
     lib/scout/workflow/python/task.rb        |  3 +-
     test/scout/python/test_util.rb           |  13 +++
     test/scout/test_python.rb                |  10 ++
     test/scout/workflow/python/test_task.rb  |  74 +++++++++++-
     test/test_helper.rb                      |  5 +
     12 files changed, 339 insertions(+), 38 deletions(-)

(The five not-ours rows carry the same +/- counts as before the edits; only
their width padding differs. `git diff <not-ours files>` is byte-identical to
the pre-edit diff.)

Cross-link/render sanity: every relative `.md` link in the four edited files
resolves (`realpath` check over all link targets: OK), and the two
intra-document anchors (`#python-interpreter-selection-for-the-suite`,
`#optional-prerequisite-gating-with-the-availability-helpers`) match existing
`###` headings at lines 160 and 214 of TestingAndPackaging.md.

Post-edit suite re-run: `53 tests, 204 assertions, 0 failures, 0 errors,
0 pendings, 1 omissions, 0 notifications`, exit 0 — docs-only change did not
disturb the suite.
Post-edit suite re-run: `53 tests, 204 assertions, 0 failures, 0 errors,
0 pendings, 1 omissions, 0 notifications`, exit 0 — docs-only change did not
disturb the suite.

Honesty flag (added after the Critic gate caught its absence): the
`53 tests, 206 assertions` example block in `doc/user/TestingAndPackaging.md`
(the torch-bearing-PATH scenario) is DERIVED ARITHMETIC, NOT an executed run —
204 assertions were actually observed in the torch-less run, plus the exactly-2
`assert`s inside `test_binding` counted from its source, giving 206 as the
expected figure. No torch interpreter exists in this environment (the baseline
recorded `PyCall::PyError: No module named 'torch'` for exactly that reason),
so that run could not have been executed here; the doc block is framed as an
expected/derived total, not captured output.

## Step 6 packaging evidence

Date: 2026-10-11. HEAD `386954a4`, VERSION 0.2.6 (unchanged by this step).
All commands run from the checkout root (`/bulk/mvazque2/git/scout-rig`).

### 1. Status before staging

`git status --porcelain` (snapshot kept at `tmp/step6-status-before.txt`):

```
 M README.md
 M doc/developer/Architecture.md
 M doc/developer/PythonWorkflowInternals.md
 M doc/user/DefiningPythonTasks.md
 M doc/user/PythonEnvironments.md
 M doc/user/TestingAndPackaging.md
 M lib/scout/python/script.rb
 M lib/scout/workflow/python/task.rb
 M test/scout/python/test_util.rb
 M test/scout/test_python.rb
 M test/scout/workflow/python/test_task.rb
 M test/test_helper.rb
?? lib/scout-rig/
?? research/testing-availability-baseline.md
?? test/scout-rig/
```

### 2. Staging (explicit paths only)

```
git add lib/scout-rig/testing/availability.rb \
        test/scout-rig/testing/test_availability.rb \
        research/testing-availability-baseline.md \
        test/test_helper.rb test/scout/test_python.rb \
        test/scout/python/test_util.rb \
        README.md doc/user/TestingAndPackaging.md \
        doc/user/PythonEnvironments.md doc/developer/Architecture.md
```

Status after (`tmp/step6-status-after-add.txt`): the 10 ours-files staged
(`A`/`M ` in column 1); the 5 not-ours files remain ` M` — unstaged.
Verification `git diff --cached --name-only | grep -E '<the 5 not-ours
paths>'` → no match ("none of the 5 not-ours files staged (correct)").

Staged set (exactly 10):
`README.md`, `doc/developer/Architecture.md`, `doc/user/PythonEnvironments.md`,
`doc/user/TestingAndPackaging.md`, `lib/scout-rig/testing/availability.rb`,
`research/testing-availability-baseline.md`,
`test/scout-rig/testing/test_availability.rb`, `test/scout/python/test_util.rb`,
`test/scout/test_python.rb`, `test/test_helper.rb`.

### 3. Gemspec regeneration

`rake gemspec` → `Generated: scout-rig.gemspec` / `scout-rig.gemspec is
valid.`, exit 0 (full output is 2 lines; `rake gemspec:validate` → `nil
versions are discouraged and will be deprecated in Rubygems 4` +
`scout-rig.gemspec is valid.`, exit 0 — the "nil versions" line is the known
Juwelier lint noise, plus the two `gem build` warnings about the open-ended
`pycall (> 0)` dependency and missing `required_ruby_version`; neither blocks
the build).

`git diff --stat scout-rig.gemspec`: `33 ++++++++++++++++++++++++++++++---`
(1 file changed, **30 insertions(+), 3 deletions(-)**). Full diff kept at
`tmp/step6-gemspec.diff` (pre-regeneration copy at
`tmp/step6-gemspec-before.gemspec`).

File-list changes — **29 entries added, 2 removed**:

- Removed (2): the stale nonexistent `doc/Python.md`, `doc/PythonWorkflow.md`.
- Added: 20 tracked-but-previously-omitted files (18 `doc/**`, 1
  `python/scout/task_errors.py`, plus our newly tracked set) and 9 of ours
  (the 3 brand-new files: `lib/scout-rig/testing/availability.rb`,
  `test/scout-rig/testing/test_availability.rb`,
  `research/testing-availability-baseline.md`; the file list picks up the
  tracked content of the 7 modified ours-files too, but for those the entry
  itself was already listed — only the 3 new paths are new entries).
- Our entries appearing in `s.files` for the first time (3):
  `lib/scout-rig/testing/availability.rb`,
  `test/scout-rig/testing/test_availability.rb`,
  `research/testing-availability-baseline.md`.
- Also regenerated: `s.rubygems_version "3.7.0.dev" -> "3.7.2"` (recording
  the running rubygems); `s.date` remains the Juwelier placeholder
  `1980-01-02`, as before.

The regenerated list includes the 5 not-ours files (`doc/developer/
PythonWorkflowInternals.md`, `doc/user/DefiningPythonTasks.md`,
`lib/scout/python/script.rb`, `lib/scout/workflow/python/task.rb`,
`test/scout/workflow/python/test_task.rb`): they are already tracked in the
repo, so Juwelier's `git ls-files` listing is legitimate and expected. Only
the file LIST regenerated, not their contents; their working-tree changes
stay unstaged.

### 4. Build and payload verification

```
gem build scout-rig.gemspec
  # WARNING: open-ended dependency on pycall (> 0) is not recommended
  # WARNING: make sure you specify the oldest ruby version constraint ... required_ruby_version
  #   Successfully built RubyGem
  #   Name: scout-rig
  #   Version: 0.2.6
  #   File: scout-rig-0.2.6.gem      (166400 bytes)
```

Payload listing (kept at `tmp/step6-payload-list.txt`, 60 entries):

```
tar -xOf scout-rig-0.2.6.gem data.tar.gz | tar -tzf -
```

**Payload verdict — `lib/scout-rig/testing/availability.rb` IS in the gem**
(payload line 25).

Ours-files in the payload (all 10, sorted as listed):
`README.md` (l4), `doc/developer/Architecture.md` (l9),
`doc/user/PythonEnvironments.md` (l20),
`doc/user/TestingAndPackaging.md` (l23),
`lib/scout-rig/testing/availability.rb` (l25),
`research/testing-availability-baseline.md` (l50),
`test/scout-rig/testing/test_availability.rb` (l53),
`test/test_helper.rb` (l60), plus `test/scout/test_python.rb` and
`test/scout/python/test_util.rb` (both listed, see the full payload list).
I.e. **nothing of ours is dev-only: every ours-file ships** in this gem's
payload. This is by Juwelier design here: `.document` only drives RDoc
(`lib/**/*.rb`, `bin/*`, `features/**/*.feature`, `LICENSE.txt` — with the
`- ` marker suppressing the default `README`/`lib` auto-inclusion), while
`s.files` is the whole tracked file set, so tests and research/ notes are
packaged as well (60 files total, 10 under `lib/`).

### 5. Nothing-else-broke checks

- `ruby -Ilib -e "require 'scout-rig/testing/availability'; puts :ok"` →
  `ok`, exit 0.
- `rake test | tail -5` → `53 tests, 204 assertions, 0 failures, 0 errors,
  0 pendings, 1 omissions, 0 notifications` / `100% passed`, exit 0
  (baseline preserved).

### 6. Cleanup and final state

`scout-rig-0.2.6.gem` removed (`rm -f`; `ls scout-rig-*.gem` → "No such file
or directory"). It was never git-ignored (root-level, outside `pkg`/`tmp`),
so removal was required rather than optional. Evidence snapshots live under
the ignored `tmp/` (`step6-status-before.txt`, `step6-status-after-add.txt`,
`step6-gemspec-before.gemspec`, `step6-gemspec.diff`, `step6-gem-build.log`,
`step6-payload-list.txt`, `step6-added.txt`, `step6-removed.txt`,
`step6-status-final.txt`) and do not appear in `git status`.

Final `git status --porcelain` (`tmp/step6-status-final.txt`): the 10
ours-files staged + `scout-rig.gemspec` regenerated (` M`), the 5 not-ours
files still ` M` unstaged, nothing else. **No commit made**: the tree holds
unrelated in-flight work and committing is outside this step's authority;
staging is exactly what Juwelier's file-list generation reads.

## Step 8 final report (pointer)

Final consolidated report written and staged at
**`research/testing-availability-final-report.md`**. It supersedes nothing
here — this note remains the per-step evidence trail; the report is the
deliverable a follow-on Scout-AI task consumes (see its "Scout-AI handoff
contract" section).

Fresh validation runs captured for the report (2026-10-11, HEAD `386954a4`,
all from the checkout root; verbatim, none quoted from earlier steps):

1. Isolation one-liner
   `ruby -Ilib -e "require 'scout-rig/testing/availability'; puts :loaded; p defined?(PyCall)"`:

       loaded
       nil
       EXIT=0

2. Standalone focused tests
   `ruby -Ilib -Itest test/scout-rig/testing/test_availability.rb`:

       30 tests, 121 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications
       100% passed

3. Full suite `rake test` (full log at `tmp/step8-rake-test.log`):

       53 tests, 204 assertions, 0 failures, 0 errors, 0 pendings, 1 omissions, 0 notifications
       100% passed
       RAKE_EXIT=0

4. Touched-file spot checks: `test/scout/test_python.rb` →
   `1 tests, 0 assertions, 0 failures, 0 errors, 0 pendings, 1 omissions,
   0 notifications` (the torch omission, expected); `test/scout/python/test_util.rb`
   → `2 tests, 2 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions,
   0 notifications` (numpy present, gate does not fire).
5. Gem inclusion: `grep -n "scout-rig/testing" scout-rig.gemspec` →
   line 46 `lib/scout-rig/testing/availability.rb`, line 74
   `test/scout-rig/testing/test_availability.rb` (payload evidence from
   step 6, not rebuilt).
6. Process evidence: HEAD still `386954a Explain how to add extensions`;
   staged set was exactly the 10 ours-files before the report was staged;
   gemspec left unstaged on purpose; the 5 not-ours files untouched.

Expected vs observed: no discrepancy. The suite landed exactly on
53/204/0 failures/0 errors/1 omission with exit 0, and the focused file on
30/121/0/0. The single omission is the honest torch gate (torch absent in
this environment — classification: environmental, not code).

Task closed. Remaining open item for a human committer: commit the staged
11 (10 + final report) **together with the regenerated `scout-rig.gemspec`**,
and keep the 5 not-ours files in their own in-flight work.
