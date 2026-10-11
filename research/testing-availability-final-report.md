# Testing availability for scout-rig — final report (step 8 of 8)

Closing report for the testing-availability task. HEAD `386954a4`
("Explain how to add extensions"); no commit was made at any step (by
design — see Environmental failures and residuals). Full per-step history,
raw scratch outputs and the pre-edit baseline live in
`research/testing-availability-baseline.md`; this file is the consolidated,
current-state deliverable.

Everything in "Validation runs" below was executed fresh for this report
(2026-10-11); no number in it is quoted from an earlier step.

---

## Delivered API and require path

**Require (the only entry point, strictly opt-in):**

```ruby
require 'scout-rig/testing/availability'
```

That require loads `scout/testing/availability` (the scout-essentials
primitive) and **nothing else of consequence**: no scout-rig production
code, no `ScoutPython`, no PyCall bridge. Verified fresh in Validation
runs item 1: `defined?(PyCall)` is `nil` after the require.

**Module:** `ScoutRig::Testing::Availability`
(file `lib/scout-rig/testing/availability.rb`).

**Mixin:** the module extends itself, so both call styles share one
implementation and one memo store:

```ruby
# module-function style
ScoutRig::Testing::Availability.python_modules?(:torch)
# mixin style — Helpers is the very same module object, not a copy
class MyTest < Test::Unit::TestCase
  include ScoutRig::Testing::Availability   # or include ScoutRig::Testing::Helpers
  def test_x; python_modules?(:torch); end
end
```

**Every method, exactly as implemented (kwargs verbatim from the source,
not paraphrased):**

| Method | Signature | Returns |
|---|---|---|
| `python?` | `python?(executable: nil, route: DEFAULT_ROUTE, timeout: nil)` | `true` iff the selected Python exists **and runs** — sanity probe `python -c 'import sys'` must exit 0; decided on exit status, never output, never PATH existence alone |
| `python_modules?` | `python_modules?(*modules, executable: nil, route: DEFAULT_ROUTE, timeout: nil)` | `true` iff every named module imports under the selected interpreter; symbols accepted (normalized to strings); an empty list is vacuously true **only after an interpreter resolved** (no interpreter → absent-interpreter reason wins) |
| `python_modules_reason` | `python_modules_reason(*modules, executable: nil, route: DEFAULT_ROUTE, timeout: nil)` | `nil` on success; else one concise string: resolved executable path + missing module name(s) + bounded stderr tail |
| `rscript?` | `rscript?(executable: nil, timeout: nil)` | `true` iff the selected Rscript exists and runs (`Rscript --vanilla -e 'cat("ok")'` exits 0) |
| `r_packages?` | `r_packages?(*packages, executable: nil, timeout: nil)` | `true` iff every named package **loads** via `requireNamespace` (not an installation-list lookup) |
| `r_packages_reason` | `r_packages_reason(*packages, executable: nil, timeout: nil)` | `nil` on success; else resolved path + missing package list (stdout first) + stderr tail |
| `embedded_python` | `embedded_python` | the interpreter the embedded route **would** initialize: `ENV['PYTHON']` when set (blank = unset), else first of `python3`/`python` on PATH; `nil` when neither. A prediction, never a validation — it does not run the interpreter and never touches `ENV` |
| `subprocess_python` | `subprocess_python` | `'python'` when `python` is on PATH (the literal command `ScoutPython.script`/`run_file`/`python_task` spawn), else `nil`. `ENV['PYTHON']` never consulted |
| `python_routes_divergence_reason` | `python_routes_divergence_reason` | `nil` when both routes resolve (realpath, symlinks canonicalized) to the same interpreter; else one message naming both resolutions, the `ENV['PYTHON']`-vs-PATH cause, the remedy, and that no probe validates both routes |
| `reset!` | `reset!` | clears every memoized probe result; returns `nil` |

**Constants:** `DEFAULT_TIMEOUT = 30` (seconds; aligned with
`Scout::Testing::Availability::DEFAULT_TIMEOUT`), `DEFAULT_ROUTE =
:subprocess`, `ROUTES = [:subprocess, :embedded].freeze`, `REASON_TAIL =
400`, `MEMO` / `MEMO_MUTEX` (shared cache + lock), and the four frozen
probe-source constants (`PYTHON_SANITY_SOURCE`, `PYTHON_MODULES_PROBE`,
`RSCRIPT_SANITY_SOURCE`, `R_PACKAGES_PROBE`).

**R helpers are reference code only.** scout-rig ships no R execution
runtime; `rscript?` / `r_packages?` report whether R is usable *from a
test*, and there is no `route:` dimension for R for exactly that reason.

**Probe process discipline (all probes):** every launch goes through
`Scout::Testing::Availability.run_command` (bounded timeout, both streams
drained, launch failure and timeout reported on the result, not raised);
module/package names travel as process arguments to a fixed frozen probe
source and are never interpolated into Python/R source; the only rescue in
the file is a `StandardError`-scoped guard around a filesystem resolution
race — no `rescue Exception` anywhere, so `SignalException` /
`NoMemoryError` propagate instead of being cached as "unavailable".

---

## Selection semantics

**Two routes.** scout-rig runs Python in two ways, and they pick their
interpreter independently:

- **Subprocess route** — `ScoutPython.script` (`lib/scout/python/script.rb:105`)
  and `ScoutPython.run_file` (`script.rb:113-122`), which is what every
  `python_task` runs through (`lib/scout/workflow/python/task.rb`). It spawns
  the literal command `python` from PATH; `ENV['PYTHON']` is **never**
  consulted on this route.
- **Embedded route** — in-process PyCall via `lib/scout/python.rb:15`
  `PyCall.init` (no argument), which makes pycall read `ENV['PYTHON']`, else
  look for `python3` then `python` on PATH. Real `PyCall.init` also exports
  `ENV['PYTHONHOME']` for the whole Ruby process (pycall
  `libpython/finder.rb:46-51`); the probe helper never does.

**Selection precedence for the Python probes (first match wins):**

1. the `executable:` keyword (explicit; overrides everything, including pins)
2. `ENV['SCOUT_TEST_PYTHON']` — a **test-only** pin, applied to whichever
   route is being probed
3. the route default — `route: :subprocess` (the default) resolves
   `subprocess_python`; `route: :embedded` resolves `embedded_python`

R: `executable:` > `ENV['SCOUT_TEST_RSCRIPT']` > `Rscript` from PATH.

`PYTHON` and `PATH` are **production** inputs that this module never sets,
unsets or mutates. The `SCOUT_TEST_*` pins do not change production code
either; they exist for suites that must probe one absolute interpreter.

**PYTHON-vs-PATH divergence case.** The two routes can silently point at
different interpreters: `ENV['PYTHON']` selects only the embedded route,
PATH selects only the subprocess route. In this environment they coincide
(`python3` and `python` both realpath to `/usr/bin/python3.13`), which is
environmental luck, not a guarantee. `python_routes_divergence_reason`
returns `nil` when both routes canonicalize to the same absolute path, and
otherwise a message that names both resolutions ("the embedded route would
initialize X, while the subprocess route spawns the literal 'python' from
PATH (Y)"), the cause, and the remedy: **put the intended interpreter's bin
directory first on PATH and unset `PYTHON`**, so both routes resolve it. It
also reports when either side fails to resolve at all (including "neither
resolves") rather than reading as agreement. It deliberately **ignores**
`SCOUT_TEST_PYTHON`: a pin overrides probing only, and a pinned probe
silently hiding a real production divergence is exactly what the reporter
exists to expose. Likewise `embedded_python` and `subprocess_python` are
unaffected by the pin.

**Memoization semantics.** Probe results are memoized in `MEMO` (guarded by
`MEMO_MUTEX`) keyed on `[kind, canonical_realpath_of_resolved_executable,
sorted_names, timeout, route]`. Because the executable component is
re-resolved through the **current** `SCOUT_TEST_*` / `PYTHON` / `PATH` on
every call, a changed environment naturally produces a new key and re-probes.
Only **definitive** verdicts are stored — success, missing module, missing
package, broken interpreter: anything where the child reached an exit
status. A launch error or a timeout is returned to the caller but never
cached, so a transient condition cannot be frozen as "unavailable" for the
rest of the process. `reset!` (`MEMO_MUTEX.synchronize { MEMO.clear }`)
is the explicit hygiene hook: call it from test setup whenever you change
`SCOUT_TEST_PYTHON`, `SCOUT_TEST_RSCRIPT`, `PATH` or `ENV['PYTHON']` and
want a provably fresh probe. The lock is held across the probe so
concurrent test threads do not spawn duplicate children for one key.

---

## Changed tests and rationale

**Gating audit verdict (step 4, written before any edit).** Per test file:

| Test file | Optional prereq (route) | Gate decision |
|---|---|---|
| `test/scout/test_python.rb` | `torch` (:embedded — `pyimport :torch` runs in-process through `ScoutPython.binding_run`/PyCall) | **GATE** `test_binding` with `omit` + `python_modules?('torch', route: :embedded)`. The 10 `_`-disabled methods stay disabled (out of scope). |
| `test/scout/python/test_util.rb` | `numpy` (:embedded — `ScoutPython.run :numpy` and `tsv2df`/`df2tsv` run in-process via PyCall; no manifest requires it) | **GATE** `test_tuple` and `test_numpy`, same shape, naming `numpy`. |
| `test/scout/python/test_script.rb` | pandas / `scout`-py via `import scout` in the child (:subprocess) | **NO GATE** — the `scout` Python package is scout-rig's own packaged code and pandas is its manifest dependency (`python/pyproject.toml`); a missing import there is a packaging/path failure worth failing loudly. |
| `test/scout/workflow/test_python.rb` | `import scout` (:subprocess) | **NO GATE** — same own-code reasoning. |
| `test/scout/workflow/python/test_task.rb` | `import scout` in generated files (:subprocess; two tests stub `run_file` entirely) | **NO GATE** — own code required; stubbed tests need nothing. |
| `test/scout-rig/testing/test_availability.rb` | none (fakes only; 2 tests deliberately omit-gated on a real interpreter) | **NO GATE** (step-3 file, in scope by construction). |
| `test/test_helper.rb` | — | **one line added**: `require 'scout-rig/testing/availability'` after `require 'scout'`, so every test file gets the helpers without per-file requires. Test-only file, not a production entry point, so the opt-in rule holds. |

**The golden rule.** The probe governs **omission only**. The gate sits at
the top of the test method as

```ruby
omit("... #{...python_modules_reason('torch', route: :embedded)} ...") unless
  ScoutRig::Testing::Availability.python_modules?('torch', route: :embedded)
```

and the `pyimport` / `ScoutPython.run` under test still executes
**unconditionally** whenever the probe passed — a probe that says "torch is
importable" cannot mask a present-but-failing interpreter or a broken
native binding.

**Stub-probe check (recorded, throwaway, not committed).** With a
`/tmp/golden_pre.rb` stub pre-loaded that makes `python_modules?` return
`true` and `python_modules_reason` return `nil` (a probe that lies "torch
is importable"), running the real `test/scout/test_python.rb --name
test_binding` produced `1 tests, 0 assertions, 0 failures, 1 errors` with
`Error: test_binding(TestPython): PyCall::PyError: <class
'ModuleNotFoundError'>: No module named 'torch'` raised from the body's
`pyimport :torch`. That is the golden rule demonstrated both ways: with the
gate satisfied the omission does not fire and the real error surfaces; with
the real probe on this machine the gate fires **before** any PyCall call,
so no spurious error occurs.

**Effect.** The stock `rake test` went from
`53 tests, 204 assertions, 0 failures, 1 errors` (exit 1) to
`53 tests, 204 assertions, 0 failures, 0 errors, ... 1 omissions` (exit 0)
on this torch-less machine; the omission text names torch, the embedded
interpreter, the missing-module reason and the remedy.

---

## Validation runs (all executed fresh 2026-10-11, checkout root)

### 1. Isolation one-liner

Command: `ruby -Ilib -e "require 'scout-rig/testing/availability'; puts :loaded; p defined?(PyCall)"`

```
loaded
nil
EXIT=0
```

Expectation met: the require loads the helper and leaves `PyCall`
undefined (`nil`), i.e. no embedded bridge is initialized by the helper.

### 2. Standalone focused tests

Command: `ruby -Ilib -Itest test/scout-rig/testing/test_availability.rb`

```
Loaded suite test/scout-rig/testing/test_availability
Started
Finished in 5.182025475 seconds.
-------------------------------------------------------------------------------
30 tests, 121 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications
100% passed
-------------------------------------------------------------------------------
5.79 tests/s, 23.35 assertions/s
EXIT=0
```

### 3. Full suite

Command: `rake test` (tail of combined output; full run kept in
`tmp/step8-rake-test.log`)

```
Finished in 17.502765803 seconds.
-------------------------------------------------------------------------------
53 tests, 204 assertions, 0 failures, 0 errors, 0 pendings, 1 omissions, 0 notifications
100% passed
-------------------------------------------------------------------------------
3.03 tests/s, 11.66 assertions/s
RAKE_EXIT=0
```

Exactly the expected shape: **53 tests / 204 assertions / 0 failures /
0 errors / 1 omission, exit 0**. (The omission is `test_binding`, torch
absent — see Environmental failures.) Unrelated stderr noise in the same
run: two `test/scout/workflow/python/test_task.rb:358: warning: method
redefined; discarding old run_file` warnings, which come from the
pre-existing not-ours working-tree changes in that file, not from anything
staged.

### 4. Touched-file spot checks

Command: `ruby -Ilib -Itest test/scout/test_python.rb`

```
Finished in 0.031946396 seconds.
-------------------------------------------------------------------------------
1 tests, 0 assertions, 0 failures, 0 errors, 0 pendings, 1 omissions, 0 notifications
0% passed
-------------------------------------------------------------------------------
31.30 tests/s, 0.00 assertions/s
EXIT=0
```

The single omission is exactly the torch gate; verbatim text:

```
Omission: torch not importable in the embedded (PyCall) interpreter: /usr/bin/python3.13: missing Python modules: torch (torch: ModuleNotFoundError: No module named 'torch'). Install torch or pin SCOUT_TEST_PYTHON to an interpreter that has it. [test_binding(TestPython)]
```

Command: `ruby -Ilib -Itest test/scout/python/test_util.rb`

```
Finished in 0.63066187 seconds.
-------------------------------------------------------------------------------
2 tests, 2 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications
100% passed
-------------------------------------------------------------------------------
3.17 tests/s, 3.17 assertions/s
EXIT=0
```

numpy is present in this environment, so both gated tests run green and
the numpy gate does not fire (as designed).

### 5. Gem inclusion (payload evidence exists in the step-6 note; not rebuilt)

Command: `grep -n "scout-rig/testing" scout-rig.gemspec`

```
46:    "lib/scout-rig/testing/availability.rb",
74:    "test/scout-rig/testing/test_availability.rb",
GREP_EXIT=0
```

The regenerated gemspec file list carries both the helper and its test.
Per step 6 (see baseline note), `gem build` + payload listing additionally
confirmed `lib/scout-rig/testing/availability.rb` at payload line 25 of
`scout-rig-0.2.6.gem`, with all 10 ours-files shipping (the built `.gem`
was then removed). Nothing was rebuilt for this report.

### 6. Process evidence

```
$ git log -1 --oneline
386954a Explain how to add extensions

$ git diff --cached --name-only
README.md
doc/developer/Architecture.md
doc/user/PythonEnvironments.md
doc/user/TestingAndPackaging.md
lib/scout-rig/testing/availability.rb
research/testing-availability-baseline.md
test/scout-rig/testing/test_availability.rb
test/scout/python/test_util.rb
test/scout/test_python.rb
test/test_helper.rb
```

(10 entries before this report; after this report and the baseline-note
pointer are staged, 11 — see the closing Process state below.)

`git status --porcelain` classification at the time of writing: the 10
ours-files staged; `scout-rig.gemspec` unstaged-modified (regenerated by
step 6, left unstaged on purpose); 5 modified tracked files that are
**not ours and untouched** (`doc/developer/PythonWorkflowInternals.md`,
`doc/user/DefiningPythonTasks.md`, `lib/scout/python/script.rb`,
`lib/scout/workflow/python/task.rb`, `test/scout/workflow/python/test_task.rb`).

---

## Environmental failures and residuals

1. **torch is absent in this environment — honest omission.** The single
   omission in every suite run is `test_binding`, gated by
   `python_modules?('torch', route: :embedded)`. torch is required by no
   `lib/` code and no manifest (`python/pyproject.toml` requires only
   pandas), so omitting (not failing, not silently passing) is the correct
   classification. Nothing in the staged change set masks a real failure.

2. **scout-essentials checkout-vs-gem packaging gap (the top residual
   risk).** The helper's only dependency beyond stdlib is
   `require 'scout/testing/availability'`. In **this** environment that
   file is provided by the scout-essentials **git checkout**
   (`/home/mvazque2/git/scout-essentials/lib/scout/testing/availability.rb`,
   where it is a staged-but-uncommitted addition; reference HEAD `759db2e`),
   reached through `RUBYOPT -I`. The **released scout-essentials 1.9.1 gem
   does not ship that file** (verified for 1.9.1, 1.9.0 and 1.8.8).
   Consequence: any environment that resolves the released gem instead of
   the checkout will fail the `require` with LoadError. scout-essentials
   must ship `scout/testing/availability` (and this checkout's gemspec
   gains nothing by hard-coding a gem version — it does not today) before
   the helper works outside a checkout-pinned environment.

3. **Juwelier noise — known and non-blocking.** `rake gemspec` /
   `gemspec:validate` emit `nil versions are discouraged and will be
   deprecated in Rubygems 4`, and `gem build` warns about the open-ended
   `pycall (> 0)` dependency and the missing `required_ruby_version`.
   All three were present before this task; none blocks build, test or
   staging.

4. **The `206 assertions` doc figure is predictive arithmetic, not an
   executed run.** `doc/user/TestingAndPackaging.md` presents a
   torch-bearing-PATH scenario with `53 tests, 206 assertions`. That
   figure is derived: 204 assertions actually observed on this torch-less
   machine plus the exactly-2 `assert`s inside `test_binding` counted from
   its source. **No torch interpreter exists in this environment, so that
   run could not have been executed here**; the doc block is framed as an
   expected/derived total, not captured output. (This paragraph is the
   honesty flag added after the Critic gate caught its absence.)

5. **No commit was made; staged-only state is deliberate.** The working
   tree carries unrelated in-flight work (the 5 not-ours modified files,
   which predate this task and were never touched). Committing was judged
   outside this task's authority, so the deliverable is the staged set
   plus the unstaged regenerated gemspec.

6. **What a future committer must know.** Commit the **staged ours-files
   together with the regenerated `scout-rig.gemspec`** (i.e. `git add
   scout-rig.gemspec` before the commit, or `git commit` the staged 11 and
   then a second commit for the gemspec — one commit is cleaner). The
   gemspec's file list is what ships the helper in the gem; committing
   code without it ships a helper the gem omits. Do **not** fold the 5
   not-ours files into the same commit: they belong to the separate
   "Python exception support / extensions" work that is still in flight.
   Note the gemspec also legitimately re-lists those 5 files (Juwelier
   reads `git ls-files`); only the LIST regenerated, their contents stay
   unstaged.

7. **Minor residuals (recorded, accepted).** `REASON_TAIL = 400` chars per
   reason; the memo lock is held across each probe (serializes concurrent
   probes for one key — a performance choice); `reset!` has no query
   counterpart; R helpers remain unwired to any live scout-rig runtime by
   design. The `_`-disabled tests in `test/scout/test_python.rb` (10
   methods) were left disabled as out of scope.

---

## Scout-AI handoff contract

This is the recipe a follow-on Scout-AI task consumes. The helper is
shipped and green; use it exactly like this.

**Require path (the only entry point, opt-in from test code only; never
required by production or entry files):**

```ruby
require 'scout-rig/testing/availability'
```

**Probe calls to use:**

```ruby
# Python modules (symbols or strings):
ScoutRig::Testing::Availability.python_modules?('torch', route: :embedded)      # => true/false
ScoutRig::Testing::Availability.python_modules_reason('torch', route: :embedded) # => nil, or human-usable diagnostic
# R packages (reference probes; scout-ai has no scout-rig R runtime either):
ScoutRig::Testing::Availability.r_packages?('base')        # => true/false
ScoutRig::Testing::Availability.r_packages_reason('base')  # => nil, or diagnostic
```

Prefer the `_reason` form inside an `omit` message: it already names the
resolved interpreter, the missing names and the condensed stderr tail.

**Route choice guidance.** Probe the route the code under test will
actually take:

- `route: :embedded` when the test runs Python **in-process through
  PyCall** (`ScoutPython.run`, `binding_run`, `pyimport`, ...). The gate
  in `test_binding` uses exactly this.
- default `route: :subprocess` (i.e. omit the kwarg) when the test runs
  Python **in a child process** (`ScoutPython.script`, `run_file`,
  `python_task`), because that route spawns the literal `python` from PATH.

If you are unsure, or run both in one process, call
`ScoutRig::Testing::Availability.python_routes_divergence_reason`; a
non-nil return means the two routes would use different interpreters and
no single probe certifies both — fix the environment (intended
interpreter's bin first on PATH, `PYTHON` unset) rather than probing
harder.

**Gating pattern (the exact shape used in scout-rig's own tests):**

```ruby
def test_binding
  omit(
    "torch not importable in the embedded (PyCall) interpreter: " \
    "#{ScoutRig::Testing::Availability.python_modules_reason('torch', route: :embedded)}. " \
    'Install torch or pin SCOUT_TEST_PYTHON to an interpreter that has it.'
  ) unless ScoutRig::Testing::Availability.python_modules?('torch', route: :embedded)

  # body runs unconditionally once the gate passes
  ScoutPython.binding_run { pyimport :torch }
end
```

Test-only pin when a suite must probe one absolute interpreter:
`ENV['SCOUT_TEST_PYTHON'] = '/path/to/python'` (and
`SCOUT_TEST_RSCRIPT` for R); call `reset!` after changing it, `PATH` or
`ENV['PYTHON']` in-process. Remember the pin applies to **probing only**
and deliberately hides nothing from `python_routes_divergence_reason`.

**Never mask PyCall failures (the golden rule, restated).** The probe
gates **omission only**. Never wrap the `pyimport`/`ScoutPython.run` call
itself in a probe guard, never `begin/rescue` a native-binding failure into
a skip, and never omit on anything that is not a genuinely optional
dependency: a missing module in scout-rig's **own** `scout` Python package
is a packaging failure and must fail loudly. Once the probe passes, the
import under test runs unconditionally — that is what keeps a
present-but-broken interpreter visible.

**No-network guarantee.** Every probe launches only the local interpreter
(`-c` / `-e` with fixed, frozen probe source; module and package names
arrive as argv, never interpolated into source). No probe performs any
network access; ordinary unit tests stay offline. (A generic
`tcp_reachable?` exists on the scout-essentials primitive, but nothing in
this helper calls it.)

**Where the fuller docs live:**

- `doc/user/TestingAndPackaging.md` — the full user-facing reference: API
  table, result meanings, selection precedence, route semantics and
  divergence, the gating recipe.
- `doc/user/PythonEnvironments.md` — the two-route interpreter split, the
  `PYTHONHOME` side effect of a real `PyCall.init`, and the
  bin-first-on-PATH remedy.
- `README.md` — short pointer plus one gating example.
- `research/testing-availability-baseline.md` — per-step evidence, raw
  runs, the pre-edit baseline, and the scout-essentials handoff digest
  (which scopes endpoint/model/accelerator probes to scout-ai, **not**
  scout-rig — do not add `cuda?` / `hf_model_cached?` / `endpoint_*` /
  `InfrastructureProbes` here).

Layer boundary, restated: scout-essentials owns the generic primitives
(`executable?`, `run_command`, `tcp_reachable?`); scout-rig owns the
interpreter knowledge (`python_modules?`, `r_packages?`, routes,
divergence); scout-ai owns the endpoint/model/accelerator layer.

---

*Report written 2026-10-11 against HEAD `386954a4`, staged set of 10
ours-files (11 with this report), no commits. All validation outputs in
this file were captured fresh for this report.*
