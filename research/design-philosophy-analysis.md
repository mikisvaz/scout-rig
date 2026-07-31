# Design Philosophy and Patterns Analysis

> **Non-normative.** Investigation artifact.

## Overview

Scout-rig follows the established Scout/Rbbt design philosophy. This
analysis identifies the key principles and patterns that make the code
expressive and elegant, and contrasts them with common anti-patterns.

## Core design principles

### 1. Thin wrappers over powerful primitives

ScoutPython doesn't reimplement PyCall — it wraps it ergonomically. Each
execution mode adds one layer of concern:

- `run_direct`: raw PyCall eval, no sync, no init.
- `run_simple`: synchronization + module_eval.
- `run`: init + run_simple + GC.
- `run_threaded`: queue + dedicated thread + init.
- `run_log`: run + stderr/stdout capture.

Each layer composes the previous. This is idiomatic Scout: build complexity
by layering thin wrappers.

**Idiomatic:**
```ruby
# Each mode composes the one below it
def run(mod = nil, imports = nil, &block)
  init_scout
  res = run_simple(mod, imports, &block)
  GC.start
  res
end
```

**Non-idiomatic:**
```ruby
# Reimplementing everything from scratch for each mode
def run(mod, imports)
  PyCall.init
  # ... 20 lines of sync logic ...
  # ... 10 lines of import logic ...
  # ... 5 lines of GC logic ...
end

def run_threaded(mod, imports)
  PyCall.init
  # ... 20 lines of sync logic ...
  # ... 10 lines of import logic ...
  # ... 15 lines of thread management ...
end
```

### 2. Metadata-driven task definition

PythonWorkflow doesn't require the user to declare inputs manually — it
discovers them from the Python function's signature. This is the Scout
convention of "convention over configuration" applied to cross-language
interop.

**Idiomatic (scout-rig style):**
```ruby
# python_task discovers everything from the Python function
python_task :hello

# In hello.py:
# def hello(name: str, excited: bool = False) -> str: ...
```

**Non-idiomatic:**
```ruby
# Manually declaring every input on the Ruby side
input :name, :string, "Name"
input :excited, :boolean, "Excited?", default: false
task :hello => :string do |name, excited|
  # run python manually
end
```

### 2b. The decorator as cross-language glue

The `scout.task` decorator is a beautiful example of Scout philosophy: the
Python function's docstring and type hints become the source of truth for
metadata, CLI help, and Scout task declaration. One function definition
serves three audiences (Ruby, Python CLI, LLM tool schemas).

### 3. Execution at the right level of isolation

Scout-rig provides multiple execution strategies, each appropriate for
different isolation requirements:

| Need                        | Mechanism           | Tradeoff              |
|-----------------------------|---------------------|-----------------------|
| Quick one-liner             | `run_direct`        | No sync, no GC        |
| General purpose             | `run`               | Safe, slightly slower |
| Background work             | `run_threaded`      | Isolated thread       |
| Full script with variables  | `script()`          | New process, clean    |
| Scout task                  | `python_task`       | New process per run   |

The philosophy is: let the user choose the isolation level. Don't force a
single execution strategy.

### 4. Subprocess for clean isolation

When the Python code is complex, untrusted, or needs to be run repeatedly
with different inputs, scout-rig spawns a subprocess. This avoids GIL
contention, memory leaks, and state contamination. The `script()` facility
and `python_task` execution both use subprocesses.

### 5. The "setup" pattern

Like other Scout modules, ScoutPython uses class-level setup that happens
lazily on first use:

```ruby
def self.init_scout
  return if @@__init_scout_python
  PyCall.init
  # ...
  @@__init_scout_python = true
end
```

This is the same pattern used by `Persist`, `CMD`, and other Scout modules:
expensive initialization happens once, on demand, and is guarded by a
class variable.

### 6. Fluent, block-based API

The execution APIs accept a block that is `instance_exec`'d in a context
where PyCall imports are available as local methods:

```ruby
ScoutPython.run :numpy, as: :np do
  np.array([1,2,3]).sum
end
```

The `as:` alias makes the code read naturally. This is similar to how
Scout workflows use blocks for task definitions.

### 7. Data flows through files, not memory

For cross-process communication (script() and python_task), data flows
through files: TSV values are written to temp files, results are pickled/
JSON'd to temp files. This is the Unix philosophy applied to cross-language
interop: use files as the universal interface.

## Anti-patterns observed

### A1. Unused `err` variable in error handling

In `task.rb`, `read_python_metadata`:
```ruby
raise "Error getting metadata for #{File.basename(file)}: #{err}"
```
The variable `err` is never assigned. The error message will always show
empty/nil for the error detail. This is a bug.

### A2. Dead code: `save_inputs` in workflow.py

```python
def save_inputs(directory, inputs, types):
    return
```
This is a stub that was never implemented. It should either be implemented
or removed.

### A3. `binding_run` ignores its parameter

```ruby
def self.binding_run(binding = nil, *args, &block)
  binding = new_binding   # always creates new, ignores parameter
  binding.instance_exec *args, &block
end
```
The `binding` parameter is overwritten immediately. This is misleading.

### A4. Path duplication in sys.path

`process_paths` appends paths without deduplication. Called multiple times
during initialization, it can add the same paths repeatedly.

### A5. Hardcoded command names

The Python `scout` package hardcodes `rbbt` and `rbbt_exec.rb`. In Scout
installs, these may be `scout` or `scout_exec`.

### A6. The `at_exit` hook kills ALL non-main threads

```ruby
at_exit do
  Thread.list.each do |thread|
    next if thread == Thread.main
    thread.kill
    thread.join rescue nil
  end
  GC.start
  # ...
end
```
This kills threads not related to Python, which could interfere with other
threading code.

## Comparison with scout-essentials conventions

Scout-rig follows the same conventions as scout-essentials:

- **Annotations:** ScoutPython uses class variables (`@@__init_scout_python`)
  for one-time initialization, similar to how scout-essentials modules use
  class-level state.
- **Paths:** Uses `Path.add_path` and `Path.caller_lib_dir` from
  scout-essentials.
- **Commands:** Uses `CMD.cmd` and `CMD.cmd_log` from scout-essentials.
- **Logging:** Uses `Log.trap_std`, `Log.trap_stderr`, and `Log::ProgressBar`
  from scout-essentials.
- **Streams:** Uses `ConcurrentStreamProcessFailed` from scout-essentials.
- **TSV:** Uses `TSV.setup`, `TSV.open` from scout-essentials.
- **TmpFile:** Uses `TmpFile.with_file` from scout-essentials.

For understanding these foundational concepts, see the
[scout-essentials documentation](https://github.com/mikisvaz/scout-essentials/blob/main/doc/user/WorkingWithFiles.md).

## Summary

Scout-rig embodies the Scout philosophy through:

1. **Layered thin wrappers** over PyCall.
2. **Metadata-driven design** that eliminates boilerplate.
3. **Multiple isolation levels** for different use cases.
4. **Files as the universal interface** for cross-process communication.
5. **Block-based, fluent APIs** that read naturally.
6. **Lazy initialization** guarded by class variables.

The code is compact (710 Ruby lines, 946 Python lines) and expressive.
The main areas for improvement are the anti-patterns identified above,
particularly the unused error variable (A1), dead code (A2), and the
ignored parameter (A3).
