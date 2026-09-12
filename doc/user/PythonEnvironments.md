# Python Environments

This document explains how Python environments relate to scout-rig, who is
responsible for setting them up, and why embedding Python inside a Ruby
process makes native-library compatibility a real concern.

## Audience

This page is intended for:

- ✓ Anyone installing or deploying a project that uses scout-rig
- ✓ Workflow authors who hit import errors or native-library conflicts
- ✓ System administrators packaging Scout for a cluster or container
- ✗ Framework contributors looking for PyCall internals (see
  [ScoutPython Internals](../developer/ScoutPythonInternals.md))

## When to use this

Read this page when:

- You are choosing or building the Python environment a Scout process will
  use.
- A Python package fails to import inside Ruby but works from a plain
  `python` shell.
- You are combining several workflows with different Python requirements
  into one project.
- You need to mix an environment manager (conda, micromamba, a virtualenv
  shipping its own native libraries) with a long-lived Scout process.

## Core concepts

### Scout does not manage Python environments

Scout-rig has no environment manager and no dependency resolver. It expects
an interpreter, its standard library and all required packages (at minimum
`numpy` and `pandas`, plus `requests` for the remote workflow client) to
already be installed and reachable, and it hands that interpreter over to
PyCall. Selection of *which* interpreter is supplied through the normal
PyCall configuration — notably the `PYTHON` environment variable, which
`PyCall.init` reads by default — plus `PATH` resolution when `PYTHON` is
unset.

Concretely, PyCall resolves the interpreter by interrogating the `python`
found on `PATH` (or `ENV['PYTHON']`), locates the matching `libpython`
shared library and `dlopen`s it into the running Ruby process. Two
consequences follow:

- The environment must be correct *before* Scout starts. Scout does not
  install, activate or repair environments.
- Whatever environment is selected, its native libraries become libraries
  *of the Ruby process itself*.

### Embedded Python shares the Ruby process's native library namespace

In-process Python (the `ScoutPython.run*` family) is not a subprocess. When
`ScoutPython.init_scout` calls `PyCall.init`, `libpython` is mapped into the
Ruby process, and from then on every native extension that Python loads
(`_ssl`, `_multiarray_umath`, `_ctypes`, ...) is `dlopen`ed into the same
process. Python and Ruby therefore negotiate one shared set of native
dependencies.

That is usually invisible, but it matters when the selected environment
supplies its own copies of libraries the Ruby process already has — a very
common situation with conda/micromamba environments or virtualenvs that
bundle OpenSSL, `libffi`, `zlib`, `libxml2`, BLAS/LAPACK and friends. Ruby
has already loaded, say, the system `libssl`; if the embedded Python then
wants the environment's `libssl` built against a different OpenSSL major
version, you can get duplicate symbols, subtly wrong behaviour, or a crash
deep inside `import ssl`, `import numpy` or `import pandas` — none of which
fail when the same environment is used from a plain `python` process,
because that process never loads the Ruby side of the conflict.

These failures are hard to diagnose precisely because they disappear when
the Python code is tested standalone.

### ScoutPython manages `sys.path` only — never native libraries

`lib/scout/python/paths.rb` is deliberately narrow. It maintains
`ScoutPython.paths` (seeded at load time from `Scout.python.find_all`, i.e.
the repository's own `python/` directory) and `process_paths` appends those
directories to Python's `sys.path`. That is all it does. It never sets
`LD_LIBRARY_PATH`, `PYTHONHOME`, `PYTHONPATH` or any other loader
variable, and it never `dlopen`s anything; native library resolution is
entirely up to the dynamic linker and to PyCall's own libpython discovery.

### Subprocess execution is a different world

`ScoutPython.script`, `ScoutPython.run_file`, and Python-backed workflow
tasks defined with `python_task` do **not** embed anything: each one runs a
separate `env PYTHONPATH=... python` process. They inherit the environment
of the Scout process, so the same environment-selection guidance applies,
but native-library conflicts with Ruby cannot happen there because Ruby and
Python never share a process.

## Typical usage

### One environment per project

Use a single Python environment per Ruby project, containing everything
that project and all its workflows need. If two workflows need different
things, build one environment with the union of both requirement sets
rather than trying to load several environments into one process. Mixing
environments inside one embedded interpreter is not a supported
configuration: once `libpython` and its dependencies are loaded, they cannot
be swapped for a different environment in the same process.

For projects whose native dependencies are genuinely irreconcilable, the
general alternative is process isolation — run the conflicting Python code
in a separate process. Scout-rig's subprocess-based facilities
(`ScoutPython.script`, `ScoutPython.run_file`, and `python_task` task
execution) are already exactly that, so they double as the practical escape
hatch.

### Establish native library paths before the process starts

Native library search paths are resolved by the dynamic loader when a
library is first mapped, and `libpython` is mapped during the first
`ScoutPython` call. Setting or changing `LD_LIBRARY_PATH` from inside Ruby
afterwards is generally too late: the loader consults it at load time, not
per call, and the conflicting library may already be resident.

For a conda or micromamba environment, activate it and export its library
directory before launching scout-ai:

```bash
micromamba activate python3
export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:$LD_LIBRARY_PATH"
scout-ai workflow task MyWorkflow my_python_task
```

Environment activation scripts are the automated alternative: placing the
`export` in the environment's activation hook (for conda/micromamba,
`etc/conda/activate.d/*.sh`) means every activation sets the loader path
for you, so no manual step is needed before launching the Ruby process.

Note that `PYTHON` (which selects the interpreter PyCall embeds) and
`LD_LIBRARY_PATH` (which selects where the loader looks for shared
libraries) are complementary: the first picks *which* Python, the second
picks *which native copies* satisfy the Python and Ruby sides. Configure
both before the process starts.

## Common mistakes

### Assuming Scout will activate an environment

Scout-rig never activates anything. Whatever `python`/`PYTHON` resolves to
at the moment Scout first touches PyCall is the environment you get, and
activation state is only inherited if it was already applied to the
launching shell (or service unit, container entrypoint, etc.).

### Fixing a native conflict by editing `LD_LIBRARY_PATH` at runtime

Changing `ENV['LD_LIBRARY_PATH']` from Ruby after the process has started
does not change how the loader resolves later `dlopen`s of already-resident
dependencies, and the first Python import may already have pulled the
conflicting library in. Fix it in the launching environment instead.

### Testing the environment standalone and concluding it is safe

`python -c "import numpy"` succeeding proves the environment is internally
consistent, not that it is consistent *with the Ruby process it will be
embedded into*. Reproduce problems through scout-rig itself.

### Reading `ScoutPython.paths` as environment configuration

`ScoutPython.add_path`/`add_paths` only extend `sys.path` for Python module
imports. They cannot add native libraries, and cannot repair a
`libssl`/BLAS version conflict.

## See also

- [Running Python from Ruby](RunningPythonFromRuby.md) — The in-process
  execution modes this page talks around.
- [ScoutPython Internals](../developer/ScoutPythonInternals.md) — What
  `PyCall.init` actually does inside the Ruby process.
- [Scripting Python](ScriptingPython.md) — The subprocess route, which
  sidesteps native-library sharing entirely.
