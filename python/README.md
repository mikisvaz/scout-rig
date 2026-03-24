# scout-rig Python package

This directory contains the Python companion package for scout-rig.

It provides the `scout` Python module used to:

- read and write Scout-style TSV files with pandas
- run Scout workflows from Python through the standard Scout CLI
- inspect workflow metadata
- define Python functions as Scout-compatible tasks with `scout.task(...)`
- call remote workflow servers over HTTP

The Python package is meant to work together with the Ruby Scout stack.
It does not replace the Ruby runtime. Instead, it offers a convenient Python interface on top of Scout command-line workflows and PythonWorkflow integration.

## Requirements

The package expects the Scout and Rbbt command-line tools used by the library to be available in your environment.

In particular, local workflow execution helpers use commands such as:

- `rbbt_exec.rb`
- `rbbt workflow task ...`

So, in practice, you should already have the Ruby scout-rig and related Scout packages installed and configured.

Base Python dependencies:

- `numpy`
- `pandas`

Optional dependencies:

- `requests` for the remote workflow client
- `rich` for `scout.rich(...)`

## Install from GitHub with pip

Because this repository is primarily a Ruby project and the Python package lives under `python/`, install it with the `subdirectory` fragment:

    pip install "scout-rig @ git+https://github.com/mikisvaz/scout-rig.git@main#subdirectory=python"

You can also omit the explicit package name:

    pip install "git+https://github.com/mikisvaz/scout-rig.git@main#subdirectory=python"

For editable local development from a clone of the repository:

    pip install -e python

## Optional extras

For remote workflow support:

    pip install "scout-rig[remote] @ git+https://github.com/mikisvaz/scout-rig.git@main#subdirectory=python"

For rich object inspection:

    pip install "scout-rig[inspect] @ git+https://github.com/mikisvaz/scout-rig.git@main#subdirectory=python"

## Quick example

    import scout
    import scout.workflow as sw

    wf = sw.Workflow('Baking')
    print(wf.tasks())
    print(wf.run('bake_muffin_tray', add_blueberries=True))

## PythonWorkflow example

    import scout

    def hello(name: str, excited: bool = False) -> str:
        """Generate a greeting."""
        return f"Hello, {name}{'!' if excited else ''}"

    scout.task(hello)

Then inspect metadata with:

    python hello.py --scout-metadata

## What pip installs

The pip package installs only the Python module contained in this directory.
It does not install the Ruby scout-rig gem or the rest of the Scout stack.

That separation is intentional:

- Ruby remains responsible for workflow execution and PythonWorkflow integration
- Python provides helper functions and a convenient development interface

## Package layout

- `scout.__init__` - TSV helpers, path helpers, workflow execution helpers
- `scout.runner` - `scout.task(...)` and metadata extraction for PythonWorkflow
- `scout.workflow` - local workflow wrapper
- `scout.workflow.remote` - remote workflow client

## Running a simple import test

From the repository root:

    PYTHONPATH=python python -c "import scout; print(scout.__file__)"
