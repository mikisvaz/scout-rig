# Improvements

This document lists actionable recommendations for code improvements in
scout-rig, discovered during the documentation investigation. Items are
categorized by type and marked with a status.

Status legend: ☐ Open · ✓ Resolved

---

## Bugs

### B1. Unused `err` variable in `read_python_metadata`

**Status:** ☐ Open

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

**Status:** ☐ Open

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

**Status:** ☐ Open

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

**Status:** ☐ Open

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

**Status:** ☐ Open

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

**Status:** ☐ Open

**Check:** Needs verification — `process_paths` is called in `init_scout`,
`run_simple`, and `init_thread`. If `add_paths` or `Scout.python.find_all`
produces overlapping paths, they may accumulate as duplicates in
`sys.path`.

**Suggestion:** Deduplicate paths before appending, or check if a path is
already in `sys.path` before appending.

### O3. `info` command may be outdated (scout-ai cross-reference)

**Status:** ☐ Open

This is a scout-ai issue, not a scout-rig issue. Listed here because
scout-rig's documentation references scout-ai's provenance system. See
[scout-ai Improvements](https://github.com/mikisvaz/scout-ai/blob/main/doc/Improvements.md).

---

## Architecture / Design

### A1. `script()` exception handling

**Status:** ☐ Open

**Location:** `lib/sccript/script.rb`

When `script()` calls a Python subprocess that errors, the error is raised
as `ConcurrentStreamProcessFailed`. The current error message does not
include the Python traceback.

**Suggestion:** Capture and include the Python traceback in the exception
message.

### A2. Return value decoding ambiguity

**Status:** `return` field in metadata is ambiguous

**Location:** `lib/scout/workflow/python/task.rb`

If a Python function returns a string that happens to be valid JSON (e.g.,
`"[1, 2, 3]"`), Ruby will JSON-parse it into a Ruby array instead of
keeping it as a string.

**Suggestion:** Add an explicit return type marker (e.g., a wrapper format)
or respect the declared return type strictly during decoding.

### A3. List input comma-split ambiguity

**Status:** ☐ Open

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

**Status:** ☐ Open

**Location:** `lib/scout/workflow downstream/python/task.rb`

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

**Status:** ☐ Open

The `iterate` helper collects all elements by default. There is no way to
stream elements one at a time from a Python generator to Ruby without
loading them all into memory.

**Suggestion:** Add a streaming iteration mode that yields elements as they
are produced by the Python generator.

### M2. No Python-side documentation for the `scout` package

**Status:** ☐ Open

The Python `scout` package has a `python/README.md` but no user-facing
documentation beyond that. The Python-side API (scout.tsv, scout.save_tsv,
scout.cmd, scout.Workflow) is not documented in a structured way.

**Suggestion:** Add a `python/docs/` directory or expand the user
documentation to cover the Python API in more detail.

### M3. No integration test for Ruby→Python→Ruby round-trip

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

**Status:** ☐ Open

The old flat documentation files `doc/Python.md` and `doc/PythonWorkflow.md`
should be removed once the new documentation is finalized, as they are
superseded by the new three-layer structure.

**Note:** Some of these old files may contain unique detail not captured
in the new documentation. Review before deleting.

### D2. Cross-reference validation

**Status:** ☐ Open

The documentation contains cross-references to scout-essentials and
scout-ai GitHub URLs. These should be validated periodically to ensure
they don't break.

---

## Priority recommendations

1. **B1 (err variable)** — Simple fix, immediate clarity improvement.
2. **B3 (binding_run)** — Simple fix, corrects a silent bug.
3. **B2 (at_exit kills all threads)** — Important for multi-threaded apps
   using ScoutPython.
4. **A2 (return decoding ambiguity)** — Could cause subtle data corruption
   if a string return is valid JSON.
5. **M3 (integration tests)** — The test suite is sparse. Adding round-trip
   integration tests would increase confidence.
