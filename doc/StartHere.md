# Scout-Rig Documentation

Scout-rig bridges the Ruby Scout framework with Python. It lets you run
Python code from Ruby, define Scout workflow tasks backed by Python
functions, and drive Scout workflows from Python.

This documentation is organized into three layers, depending on what
you're trying to do:

## Which documentation should I read?

### I want to build applications using scout-rig

→ Read the **[User Documentation](user/)**

The user docs are concept-oriented guides that teach you how to use
scout-rig to solve problems. They are organized around tasks, not classes.

**Start here:**
- [Running Python from Ruby](user/RunningPythonFromRuby.md) — Execute Python
  code from Ruby with different execution modes.
- [Passing Data to Python](user/PassingDataToPython.md) — Convert Ruby data
  to Python (TSV↔DataFrame, numpy, lists).
- [Scripting Python](user/ScriptingPython.md) — Run ad-hoc Python scripts
  with Ruby variables and get results back.
- [Defining Python Tasks](user/DefiningPythonTasks.md) — Write Scout
  workflow tasks whose logic lives in Python.
- [Driving Workflows from Python](user/DrivingWorkflowsFromPython.md) — Use
  the Python `scout` package to run Scout workflows locally or remotely.
- [Iterating Python Data](user/IteratingPythonData.md) — Traverse Python
  iterables from Ruby.
- [Cookbook](user/Cookbook.md) — Practical recipes combining multiple
  features.

### I want to understand how scout-rig is implemented

→ Read the **[Developer Documentation](developer/)**

The developer docs explain the internal architecture, key abstractions, and
design decisions behind scout-rig.

**Start here:**
- [Architecture](developer/Architecture.md) — Module map and data flow.
- [ScoutPython Internals](developer/ScoutPythonInternals.md) — PyCall
  integration, execution modes, threading, garbage collection.
- [PythonWorkflow Internals](developer/PythonWorkflowInternals.md) —
  Metadata discovery, type mapping, CLI generation.
- [Data Conversion Internals](developer/DataConversionInternals.md) —
  Serialization pipeline, pickle/JSON, subprocess management.
- [Design Principles](developer/DesignPrinciples.md) — Scout-rig coding
  philosophy and idiomatic patterns.

### I'm investigating a subsystem in deep detail

→ Read the **[Research Artifacts](../research/)**

These are curated architectural investigations. They are **non-normative**:
they may contain implementation history, abandoned ideas, and experimental
observations. They are supporting material, not primary documentation.

## Prerequisites

Scout-rig builds on the Scout framework. To understand foundational
concepts like TSV data structures, file I/O, command execution, logging,
and path resolution, see the
[scout-essentials documentation](https://github.com/mikisvaz/scout-essentials/blob/main/doc/StartHere.md).

## Documentation philosophy

- **User documentation** teaches how to build with scout-rig.
- **Developer documentation** explains how scout-rig itself is built.
- **Research artifacts** preserve the reasoning behind the current design.

Each layer becomes progressively more detailed while remaining focused on
its intended audience.
