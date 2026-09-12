# Improvements

This document lists actionable recommendations for code improvements in
scout-rig, discovered during the documentation investigation. Items are
categorized by type and marked with a status.

Status legend: ☐ Open · ✓ Resolved · ◐ Partially resolved ·
● Verified open (confirmed at HEAD, no code change yet) ·
✗ Withdrawn (premise disproved by probe)

Statuses below were reconciled in the 2026-09-12 documentation-completion
campaign against the probe evidence recorded in the Cortex artifacts under
`scout-rig/subsys/`. Each item names the artifact that carries the evidence.

---

## Bugs

### B1. Unused `err` variable in `read_python_metadata`

**Status:** ● Verified open — and the `raise` is dead code in practice
(evidence: `scout-rig/subsys/pythonworkflow.md`)

**Location:** `lib/scout/workflow/python/task.rb`

The `read_python_metadata` method references `err` in its error message:

```ruby
def self.read_python_metadata(file)
  out = ScoutPython.run_file file, '--scout-metadata'
  raise "Error getting metadata for #{File.basename(file)}: #{err}"
    unless out.exit_status == 0
  ...
end
```

But `err` is never assigned. The error message will show `nil` for the
error detail.

**Fix:** Capture stderr from `run_file` and include it:

```ruby
def self.read_python_metadata(file)
  out = ScoutPython.run_file file, '--scout-metadata'
  unless out.exit_status == 0
    err = out.stderr.read
    raise "Error getting metadata for #{File.basename(file)}: #{err}"
  end
  ...
end
```

### B2. `at_exit` hook kills all non-main threads

**Status:** ● Verified open — confirmed and worse than described: killing
foreign threads reproduced directly, and the threaded path never exits
cleanly (hang or segfault), with or without `stop_thread` (evidence:
`scout-rig/subsys/python-bridge.md`; user-facing consequences documented in
[Running Python from Ruby](user/RunningPythonFromRuby.md) and
[ScoutPython Internals](developer/ScoutPythonInternals.md))

**Location:** `lib/scout/python/run.rb` — `init_scout`

The at_exit hook iterates all threads and kills them:

```ruby
at_exit do
  GC.start
  Thread.list.each do |thread|
    next if thread == Thread.main
    thread.kill
    thread.join rescue nil
  end
  GC.start
  PyCall.builtins.object  # GIL health check
end
```

This kills ALL non-main threads, not just the ScoutPython background thread.
This could interfere with other threading code in the host process.

**Fix:** Track the ScoutPython thread explicitly and only kill that one:

```ruby
at_exit do
  ScoutPython.stop_thread if ScoutPython.thread && ScoutPython.thread.alive?
  GC.start
  PyCall.builtins.object
end
```

### B3. `binding_run` ignores its `binding` parameter

**Status:** ● Verified open — confirmed in code and by probe; documented
as actual behaviour (parameter ignored, `new_binding` always used) in
[Running Python from Ruby](user/RunningPythonFromRuby.md), with the
`new_binding` + `instance_exec` reuse pattern as the workaround (evidence:
`scout-rig/subsys/python-bridge.md`)

**Location:** `lib/scout/python.rb`

```ruby
def self.binding_run(binding = nil, *args, &block)
  binding = new_binding  # parameter overwritten!
  binding.instance_exec(*args, &block)
end
```

The `binding` parameter is overwritten by `new_binding`. If a caller passes
a binding, it is silently ignored.

**Fix:** Respect the parameter:

```ruby
def self.binding_run(binding = nil, *args, &block)
  binding ||= new_binding
  binding.instance_exec(*args, &block)
end
```

### B4. Dead code: `save_inputs` in Python `workflow.py`

**Status:** ● Verified open — still a `return`-only stub at HEAD, never
called anywhere in `python/`, `lib/`, `test/` or `Rakefile` (evidence:
`scout-rig/subsys/python-package.md`)

**Location:** `python/scout/workflow.py`

```python
def save_inputs(directory, inputs, types):
    return
```

This function is a stub that does nothing. It is never called with non-trivial
arguments and never returns anything useful.

**Fix:** Either implement it or remove it. If it was intended to implement
the `save_job_inputs` logic, it should be completed. Otherwise remove the
stub to avoid confusion.

---

## Outdated / Incomplete

### O1. No metadata caching

**Status:** ● Verified open — confirmed; ~0.42–0.48 s per registration,
interpreter startup dominating, linear in file count (evidence:
`scout-rig/subsys/pythonworkflow.md`)

**Location:** `lib/scout/workflow/python/task.rb`

Every `python_task` call runs a Python subprocess to read metadata:

```ruby
metas = read_python_metadata(file)
```

For workflows with many Python tasks, this spawns N Python processes at
definition time, which can be slow.

**Suggestion:** Cache metadata results. Options:
- Cache by file mtime (if file hasn't changed, reuse cached metadata).
- Read metadata from all files in a directory in a single subprocess call.

### O2. `process_paths` called multiple times without deduplication

**Status:** ● Verified open — refined: main-thread modes append the Scout
directory once per `run` (8→9→10 over three calls); `run_threaded` is
stable because `init_thread` only re-runs `process_paths` when recreating
the thread (evidence: `scout-rig/subsys/python-bridge.md`; quantified in
[ScoutPython Internals](developer/ScoutPythonInternals.md))

*(Verified — see the status above.)* `process_paths` is called in
`init_scout`, `run_simple`, and `init_thread`. If `add_paths` or
`Scout.python.find_all`
produces overlapping paths, they may accumulate as duplicates in
`sys.path`.

**Suggestion:** Deduplicate paths before appending, or check if a path is
already in `sys.path` before appending.

### O3. `info` command may be outdated (scout-ai cross-reference)

**Status:** ☐ Open (out of scope for this repository — scout-ai issue)

This is a scout-ai issue, not a scout-rig issue. Listed here because
scout-rig's documentation references scout-ai's provenance system. See
[scout-ai Improvements](https://github.com/mikisvaz/scout-ai/blob/main/doc/Improvements.md).

---

## Architecture / Design

### A1. `script()` exception handling

**Status:** ◐ Partially resolved — narrower than described: the *last*
traceback line is already embedded in the exception message, and the full
traceback reaches the Scout log at DEBUG severity. Documented in
[Scripting Python](user/ScriptingPython.md) and
[Data Conversion Internals](developer/DataConversionInternals.md)
(evidence: `scout-rig/subsys/data-conversion.md`)

**Location:** `lib/scout/python/script.rb`

When `script()` calls a Python subprocess that errors, the error is raised
as `ConcurrentStreamProcessFailed`. The current error message does not
include the Python traceback.

**Suggestion:** Capture and include the Python traceback in the exception
message.

### A2. Return value decoding ambiguity

**Status:** ● Verified open — confirmed end-to-end (`"[1, 2, 3]"` decodes
to Ruby `[1, 2, 3]`, `"1"` to `1`); documented as a decoding caveat in
[PythonWorkflow Internals](developer/PythonWorkflowInternals.md) and
[Defining Python Tasks](user/DefiningPythonTasks.md) (evidence:
`scout-rig/subsys/pythonworkflow.md`)

**Location:** `lib/scout/workflow/python/task.rb`

If a Python function returns a string that happens to be valid JSON (e.g.,
`"[1, 2, 3]"`), Ruby will JSON-parse it into a Ruby array instead of
keeping it as a string.

**Suggestion:** Add an explicit return type marker (e.g., a wrapper format)
or respect the declared return type strictly during decoding.

### A3. List input comma-split ambiguity

**Status:** ● Verified open — confirmed, plus two undocumented siblings:
an existing-file check shadows a literal comma-separated value (file lines
win), and bare `-`-prefixed elements break argparse (exit 2). All
documented in [Defining Python Tasks](user/DefiningPythonTasks.md) and
[PythonWorkflow Internals](developer/PythonWorkflowInternals.md) (evidence:
`scout-rig/subsys/pythonworkflow.md`)

**Location:** `lib/scout/workflow/python/inputs.rb`

In `build_python_argv`, list inputs with string values are split by comma:

```ruby
# If value is a String, split by comma
values = value.split(",")
```

If the actual data contains commas (e.g., gene names with commas, file
paths with commas), this will incorrectly split the value.

**Suggestion:** Use newline-split instead of comma-split, or detect whether
the string looks like a file path and read it as a list file.

### A4. `path` return type maps to `:string`

**Status:** ● Verified open — confirmed: input `path` maps to `:file` but
return `path` maps to `:string`; the asymmetry is documented as a known
issue in [PythonWorkflow Internals](developer/PythonWorkflowInternals.md)
(evidence: `scout-rig/subsys/pythonworkflow.md`)

**Location:** `lib/scout/workflow/python/task.rb`

When a Python function's return annotation is `pathlib.Path`, it maps to
Scout `:string` return type:

```ruby
when "path"
  :string
```

This means downstream tasks receiving this result will treat it as a
string, not as a file. This could cause issues with Scout's file-type
checking.

**Suggestion:** Consider mapping `path` returns to `:file` instead, or
adding a separate `:path` return type.

---

## Missing features / Documentation gaps

### M1. No streaming Python iterator support

**Status:** ✗ Withdrawn — the premise is false. `iterate` *is* lazy: a
generator's `__next__` is called only when the Ruby block asks for the
next element (probe: interleaved pull/consume log, 2026-09-12), so
streaming already exists today via `iterate`; documented in
[Iterating Python Data](user/IteratingPythonData.md)

*(The original description below is inaccurate — see the status above:
`iterate` pulls elements lazily, one per block iteration, and is not
verified to materialize anything up front.)*

The `iterate` helper collects all elements by default. There is no way to
stream elements one at a time from a Python generator to Ruby without
loading them all into memory.

**Suggestion:** Add a streaming iteration mode that yields elements as they
are produced by the Python generator.

### M2. No Python-side documentation for the `scout` package

**Status:** ✓ Resolved (by documentation) — `python/README.md` plus
[Driving Workflows from Python](user/DrivingWorkflowsFromPython.md) and
[Defining Python Tasks](user/DefiningPythonTasks.md) now cover the Python
API, and [Python Task Runner Internals](developer/PythonTaskRunnerInternals.md)
documents the docstring grammar and CLI output conventions. The suggested
`python/docs/` directory was not created; the existing pages were extended
instead (evidence: `scout-rig/subsys/python-package.md`)

The Python `scout` package has a `python/README.md` but no user-facing
documentation beyond that. The Python-side API (scout.tsv, scout.save_tsv,
scout.cmd, scout.Workflow) is not documented in a structured way.

**Suggestion:** Add a `python/docs/` directory or expand the user
documentation to cover the Python API in more detail.

### M3. No integration test for Ruby→Python→Ruby round-trip

**Status:** ◐ Partially resolved — stale in both directions. *Covered at
HEAD*: define a Python task, run it, verify the result
(`test/scout/workflow/test_python.rb#test_file`); TSV→DataFrame→TSV
round-trip (`test/scout/python/test_util.rb#test_tuple`). *Still
missing*: multi-function file task creation, remote workflow client
tests, threaded execution + GC tests. Note the "existing tests" list
below is itself wrong for `test_run.rb`: its `run_threaded` test is
`__test_run_threaded` (disabled), so that file runs zero tests
(evidence: `scout-rig/subsys/packaging-tests.md`; see
[Testing and Packaging](user/TestingAndPackaging.md))

*(The list below predates the campaign; the verified picture is in the
status above and in [Testing and Packaging](user/TestingAndPackaging.md).)*

**Existing tests cover:**
- `test_run.rb` — `run_threaded` basic test
- `test_script.rb` — `script()` basic and exception tests
- `test_util.rb` — numpy conversion
- `test_python.rb` — PyCall proxy behavior
- `test_task.rb` — `read_python_metadata`
- `test_python.rb` (workflow) — basic python_task

**Missing:**
- Full round-trip: define a Python task, run it, verify result type and value.
- TSV → DataFrame → TSV round-trip.
- Multi-function file task creation.
- Remote workflow client tests.
- Threaded execution + GC interaction tests.

**Suggestion:** Add integration tests covering these scenarios.

---

## Documentation-specific

### D1. Old documentation files should be removed

**Status:** ✓ Resolved in the tree, ☐ gemspec remnant — both files are
deleted at HEAD, and the last stale README links were fixed in this
campaign. The checked-in `scout-rig.gemspec` still lists both deleted
files, so a plain `gem build` fails; `rake gemspec` regenerates the list
and fixes the build (evidence: `scout-rig/subsys/packaging-tests.md`;
see [Testing and Packaging](user/TestingAndPackaging.md))

The old flat documentation files `doc/Python.md` and `doc/PythonWorkflow.md`
should be removed once the new documentation is finalized, as they are
superseded by the new three-layer structure.

**Note:** Some of these old files may contain unique detail not captured
in the new documentation. Review before deleting.

### D2. Cross-reference validation

**Status:** ☐ Open — no automated link validation exists (no CI, no link
checker, no rake task). A full manual sweep of every relative markdown
link (27 files — README.md, doc/, research/ and python/README.md; 122
links) plus the remote scout-essentials/scout-ai URLs was run at the end
of the documentation campaign and found no dead links; the sweep is not repeatable automatically until this item is
addressed (evidence: `scout-rig/subsys/doc-corpus.md`)

The documentation contains cross-references to scout-essentials and
scout-ai GitHub URLs. These should be validated periodically to ensure
they don't break.

---

## Priority recommendations

1. **B1 (err variable)** — Simple fix, immediate clarity improvement.
   (Verified: the `raise` is currently unreachable; `ProcessFailed` from
   `CMD.cmd` fires first — see the B1 status above.)
2. **B3 (binding_run)** — Simple fix, corrects a silent bug.
3. **B2 (at_exit kills all threads)** — Important for multi-threaded apps
   using ScoutPython. (Verified: also blocks clean exit of the threaded
   path altogether.)
4. **A2 (return decoding ambiguity)** — Could cause subtle data corruption
   if a string return is valid JSON. (Verified end-to-end.)
5. **M3 (integration tests)** — The test suite is sparse. Adding round-trip
   integration tests would increase confidence. (Partially covered —
   see the M3 status above.)
6. **D1 (gemspec remnant)** — Regenerate `scout-rig.gemspec` with
   `rake gemspec` so it stops listing `doc/Python.md` and
   `doc/PythonWorkflow.md`; the stale list is the only remaining blocker
   for a plain `gem build`.
7. **D2 (link validation)** — Wire the relative-link sweep used at the end
   of the campaign into a rake task so it runs before every release.
