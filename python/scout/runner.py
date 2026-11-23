import argparse
import inspect
import json
import os
import re
import sys
from pathlib import Path
from types import UnionType
# typing.get_type_hints is deliberately NOT used: inspect.signature(eval_str=True)
# already resolves postponed and quoted annotations against the module namespace
# and covers the whole supported surface; see describe_function.
from typing import Annotated, Any, get_args, get_origin, List, Union
import atexit
import runpy
import traceback

from scout.task_errors import ScoutTaskError

__all__ = ["task", "describe_function"]

# registry to hold tasks defined via scout.task in a module
_SCOUT_TASK_REGISTRY = []  # list of (func, meta)
_SCOUT_DEFER_REGISTERED = set()
_SCOUT_METADATA_BATCH = False


def _scout_metadata_files(files):
    """Collect per-file task metadata in one interpreter process."""
    results = []
    from scout import runner as task_runner
    for filename in files:
        task_runner._SCOUT_TASK_REGISTRY.clear()
        original_path = list(sys.path)
        original_argv = list(sys.argv)
        original_batch = task_runner._SCOUT_METADATA_BATCH
        sys.path.insert(0, str(Path(filename).resolve().parent))
        try:
            # Preserve __main__ conditionals without installing deferred CLI execution.
            task_runner._SCOUT_METADATA_BATCH = True
            sys.argv = [filename, "--scout-metadata"]
            runpy.run_path(filename, run_name="__main__")
        finally:
            task_runner._SCOUT_METADATA_BATCH = original_batch
            sys.path[:] = original_path
            sys.argv[:] = original_argv
        results.append({
            "file": str(Path(filename).resolve()),
            "metadata": [meta for (_func, meta) in task_runner._SCOUT_TASK_REGISTRY],
        })
    print(json.dumps(results))


if __name__ == "__main__" and "--scout-metadata-files" in sys.argv:
    flag_index = sys.argv.index("--scout-metadata-files")
    _scout_metadata_files(sys.argv[flag_index + 1:])
    sys.exit(0)


def _annotation_repr(ann) -> str:
    """Complete, human-readable annotation used for diagnostics metadata.

    Parameterized annotations are rendered in full: Annotated[Path, 'extra']
    keeps both the wrapped type and the tag instead of collapsing to the bare
    name "Annotated". The value is purely diagnostic; the annotation->Scout
    type mapping in _python_type_to_string is unaffected.
    """
    if ann is inspect.Parameter.empty:
        return ""
    if isinstance(ann, str):
        return ann
    # Bare classes keep the short name (str, Path, ...) for readability.
    if isinstance(ann, type):
        return getattr(ann, "__name__", str(ann))
    # Anything parameterized (Annotated[...], Optional[...], list[...], unions)
    # renders its complete typing form.
    text = str(ann)
    return text[len("<class '"):-len("'>")] if text.startswith("<class '") else text


def _unsupported_annotation_error(kind: str, name: str, ann) -> ValueError:
    hint = ""
    if isinstance(ann, str):
        hint = (
            f" This annotation stayed the string {ann!r}: under "
            "'from __future__ import annotations' (or any quoted annotation) "
            "it is only evaluated when the name is importable or defined in "
            "the module at registration time — import the type or define it, "
            "or annotate with the type itself rather than its name."
        )
    return ValueError(
        f"Unsupported {kind} annotation for '{name}': {ann!r}. "
        "Supported: str, bytes, int, float, bool, pathlib.Path, "
        "typing.Optional[...] of one supported type, PEP 604 unions with None "
        "(e.g. Path | None), list[...] of a supported subtype, "
        "typing.Annotated[...] of a supported type, or no annotation (string)."
        f"{hint}"
    )


def _python_type_to_string(ann, kind: str = "parameter", name: str = "?") -> str:
    if ann is inspect._empty:
        return "string"
    origin = get_origin(ann)
    args = get_args(ann)

    if origin is Annotated:
        # Keep the underlying type mapping; the Annotated metadata itself is
        # preserved in the 'annotation' field of the parameter metadata.
        if not args:
            raise _unsupported_annotation_error(kind, name, ann)
        return _python_type_to_string(args[0], kind, name)

    if origin is Union or origin is UnionType:
        non_none = [a for a in args if a is not type(None)]
        if len(non_none) == 1:
            return _python_type_to_string(non_none[0], kind, name)
        raise _unsupported_annotation_error(kind, name, ann)

    if origin in (list, List):
        if not args:
            raise _unsupported_annotation_error(
                kind, name,
                "bare list (write list[str], list[Path], ... so element types are explicit)"
            )
        subtype = _python_type_to_string(args[0], kind, name)
        return f"list[{subtype}]"

    if ann is Path:
        return "path"

    if ann is str or ann is inspect.Parameter.empty:
        return "string"
    if ann is bytes:
        return "binary"
    if ann is int:
        return "integer"
    if ann is float:
        return "float"
    if ann is bool:
        return "boolean"
    if ann is Any:
        # Explicit opt-out: the author declared the input untyped, which maps
        # deliberately (and documented) to string.
        return "string"
    if isinstance(ann, type) and issubclass(ann, (str, bytes, int, float, bool, Path)):
        # Subclasses of supported scalar types behave like their base type.
        if issubclass(ann, str):
            return "string"
        if issubclass(ann, bytes):
            return "binary"
        if issubclass(ann, bool):
            return "boolean"
        if issubclass(ann, int):
            return "integer"
        if issubclass(ann, float):
            return "float"
        if issubclass(ann, Path):
            return "path"

    raise _unsupported_annotation_error(kind, name, ann)


def _required_from_default(default_val, ann) -> bool:
    # A parameter is required iff it has no default. Optional[...] does not
    # make a parameter optional; passing None from the Ruby side is still an
    # explicit nil for a required input.
    return default_val is inspect._empty


def _parse_numpy_params(doc: str) -> dict:
    """
    Extract per-parameter documentation from a docstring.

    Despite the historical name, this parser prefers Google-style docstrings
    ("Args:") because they map cleanly to tool schemas used by AI agents.

    Supported formats:

    Google style (recommended)::

        Do something.

        Args:
            name: Description.
            flag: Description that can wrap to
                multiple indented lines.

        Returns:
            Description.

    NumPy style (legacy fallback)::

        Parameters
        ----------
        name : str
            Description.

    Returns:
        dict mapping parameter name -> description string
    """

    if not doc:
        return {}

    lines = doc.splitlines()

    # -- Google style: Args: / Arguments: -----------------------------------
    def parse_google_args() -> dict:
        params = {}
        i = 0
        # Find section header
        while i < len(lines):
            header = lines[i].strip()
            if header in ("Args:", "Arguments:"):
                i += 1
                break
            i += 1
        else:
            return {}

        # Parse items until next top-level section (Returns:, Raises:, etc.)
        current = None
        current_desc = []

        def flush():
            nonlocal current, current_desc
            if current:
                params[current] = " ".join(s.strip() for s in current_desc).strip()
            current = None
            current_desc = []

        while i < len(lines):
            raw = lines[i]
            stripped = raw.strip()

            # End conditions: next section header at left margin
            if stripped.endswith(":") and not raw.startswith((" ", "\t")):
                # Example: "Returns:", "Raises:", "Examples:", ...
                break

            # Skip empty lines between entries
            if stripped == "":
                if current is not None:
                    current_desc.append("")
                i += 1
                continue

            # Item start: indented "name:" or "name (type):"
            # We require indentation so we don't confuse it with section headers.
            if raw.startswith((" ", "\t")):
                # Google-style param line (type is optional and ignored):
                #   name: description
                #   name (str): description
                m = re.match(r"^\s*([A-Za-z_]\w*)\s*(?:\([^)]*\))?\s*:\s*(.*)$", stripped)
                if m:
                    param_name = m.group(1)
                    first_desc = m.group(2).strip()

                    if current and param_name != current:
                        flush()
                    if current is None:
                        current = param_name
                    if first_desc:
                        current_desc.append(first_desc)
                    i += 1
                    continue

            # Continuation line (more indented than the item header)
            if current is not None:
                current_desc.append(stripped)

            i += 1

        flush()
        # Drop empty descriptions
        return {k: v for k, v in params.items() if v is not None}

    google = parse_google_args()
    if google:
        return google

    # -- NumPy style fallback: Parameters / ---------- ----------------------
    params = {}
    i = 0
    while i < len(lines):
        if lines[i].strip().lower() == "parameters":
            i += 1
            if i < len(lines) and set(lines[i].strip()) == {"-"}:
                i += 1
                break
        i += 1
    else:
        return {}

    current_name = None
    current_desc = []
    while i < len(lines):
        line = lines[i]
        if ":" in line and not line.startswith(" "):
            if current_name:
                params[current_name] = " ".join(d.strip() for d in current_desc).strip()
            current_desc = []
            current_name = line.split(":")[0].strip()
        else:
            if current_name is not None:
                current_desc.append(line)
            else:
                break
        i += 1

    if current_name:
        params[current_name] = " ".join(d.strip() for d in current_desc).strip()

    return params


def _extract_description(docstring: str) -> str:
    """Extract a task description from a docstring.

    The description is the full docstring preamble (potentially multiple lines
    and paragraphs) up to the first schema-oriented section header.

    This matches common conventions in LLM tool / JSON-schema extraction:
    the preamble is the capability description, while sections like "Args:" and
    "Returns:" provide structured schema information.
    """

    if not docstring:
        return ""

    stop_headers = {
        # Google-style
        "args:", "arguments:", "returns:", "raises:", "examples:", "example:",
        "notes:", "note:",
        # NumPy-style
        "parameters", "returns", "raises", "examples", "notes",
    }

    out_lines = []
    for line in docstring.splitlines():
        stripped = line.strip()

        # Stop at first recognized header line
        if stripped and stripped.lower() in stop_headers:
            break

        out_lines.append(line.rstrip())

    # Trim leading/trailing blank lines, preserve internal blank lines.
    while out_lines and out_lines[0].strip() == "":
        out_lines.pop(0)
    while out_lines and out_lines[-1].strip() == "":
        out_lines.pop()

    return "\n".join(out_lines).strip()


def _extract_extension(docstring: str) -> tuple[str | None, str]:
    """Extract an optional standalone ``Extension: suffix`` docstring field."""
    extension = None
    found = False
    remaining_lines = []

    for line in docstring.splitlines():
        if re.match(r"^\s*Extension:", line):
            if found:
                raise ValueError("A task docstring may contain only one Extension: field")
            found = True
            extension = line.split(":", 1)[1].strip()
            if not extension or re.search(r"\s", extension):
                raise ValueError("Extension: must be followed by one non-empty suffix token")
        else:
            remaining_lines.append(line)

    return extension, "\n".join(remaining_lines)


def describe_function(func) -> dict:
    # Annotations are resolved eagerly with eval_str=True: postponed
    # annotations (`from __future__ import annotations`) and quoted forward
    # references are evaluated against the module namespace, so they map the
    # same as plain ones as long as the names resolve at registration time.
    # A name that does not resolve stays a string and fails loudly in
    # _python_type_to_string (never a silent :string mapping).
    sig = inspect.signature(func, eval_str=True)
    doc = inspect.getdoc(func) or ""
    extension, doc = _extract_extension(doc)
    params_doc = _parse_numpy_params(doc)

    ret_type = _python_type_to_string(sig.return_annotation, "return", func.__name__)
    description = _extract_description(doc)

    params = []
    for name, p in sig.parameters.items():
        p_type = _python_type_to_string(p.annotation, "parameter", name)
        default = None if p.default is inspect._empty else p.default
        required = _required_from_default(p.default, p.annotation)
        help_text = params_doc.get(name, "")
        params.append({
            "name": name,
            "type": p_type,
            "annotation": _annotation_repr(p.annotation),
            "required": required,
            "default": default,
            "help": help_text,
        })

    metadata = {
        "name": func.__name__,
        "description": description,
        "returns": ret_type,
        "params": params,
    }
    if extension is not None:
        metadata["extension"] = extension
    return metadata


def _has_boolean_optional_action():
    try:
        _ = argparse.BooleanOptionalAction
        return True
    except AttributeError:
        return False


class _BooleanOptionalAction(argparse.Action):
    def __init__(self, option_strings, dest, default=None, required=False, help=None, metavar=None):
        _option_strings = []
        for option in option_strings:
            _option_strings.append(option)
            if option.startswith("--"):
                _option_strings.append("--no-" + option[2:])
        super().__init__(option_strings=_option_strings, dest=dest, nargs=0,
                         const=None, default=default, required=required, help=help)

    def __call__(self, parser, namespace, values, option_string=None):
        if option_string and option_string.startswith("--no-"):
            setattr(namespace, self.dest, False)
        else:
            setattr(namespace, self.dest, True)


def _add_arg_for_param(parser, p):
    name = p["name"]
    ptype = p["type"]
    required = p["required"]
    default = p["default"]
    help_text = p.get("help") or None

    flag = f"--{name}"

    if ptype.startswith("list["):
        subtype = ptype[5:-1] or "string"
        py_caster = str
        if subtype == "integer":
            py_caster = int
        elif subtype == "float":
            py_caster = float
        elif subtype == "path":
            py_caster = Path
        parser.add_argument(flag, nargs="+", type=py_caster, required=required, default=default, help=help_text)
        return

    if ptype == "boolean":
        if default is True:
            if _has_boolean_optional_action():
                parser.add_argument(flag, action=argparse.BooleanOptionalAction, default=True, help=help_text, required=False)
            else:
                parser.add_argument(flag, action=_BooleanOptionalAction, default=True, help=help_text, required=False)
        else:
            parser.add_argument(flag, action="store_true", default=False, required=False, help=help_text)
        return

    py_caster = str
    if ptype == "integer":
        py_caster = int
    elif ptype == "float":
        py_caster = float
    elif ptype == "path":
        py_caster = Path

    parser.add_argument(flag, type=py_caster, required=required, default=default, help=help_text)


def _write_output(out_path: str, data):
    path = Path(out_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, (bytes, bytearray)):
        path.write_bytes(data)
    else:
        path.write_text(str(data))


def _run_cli(func, meta: dict, error_file=None):
    # single-function CLI metadata
    if "--scout-metadata" in sys.argv:
        print(json.dumps(meta))
        return 0

    parser = argparse.ArgumentParser(description=meta.get("description") or "")
    for p in meta["params"]:
        _add_arg_for_param(parser, p)

    parser.add_argument("--scout-output", default=None, help="Optional output file path for the result")
    args = vars(parser.parse_args())

    out_path = args.pop("scout_output", None)

    kwargs = {}
    for p in meta["params"]:
        name = p["name"]
        val = args.get(name)
        kwargs[name] = val

    try:
        result = func(**kwargs)
    except ScoutTaskError as exc:
        if error_file is not None:
            payload = {
                "version": 1,
                "error": "ScoutTaskError",
                "message": str(exc),
                "traceback": traceback.format_exc(),
            }
            destination = Path(error_file)
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary = destination.with_name(destination.name + ".tmp")
            temporary.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            temporary.replace(destination)
        raise

    if out_path:
        _write_output(out_path, result)
        return 0

    # Serialization rules:
    # - bytes -> raw bytes to stdout.buffer
    # - str/int/float/bool/None -> printed as plain string
    # - list/tuple -> newline-separated items
    # - others -> JSON dump
    if isinstance(result, (bytes, bytearray)):
        sys.stdout.buffer.write(result)
        return 0

    if result is None or isinstance(result, (str, int, float, bool)):
        print(result if result is not None else "")
        return 0

    if isinstance(result, (list, tuple)):
        # print each item on its own line
        for item in result:
            # convert None to empty string
            if item is None:
                print("")
            else:
                # bytes inside list -> decode
                if isinstance(item, (bytes, bytearray)):
                    try:
                        sys.stdout.buffer.write(item)
                        # ensure newline
                        sys.stdout.buffer.write(b"\n")
                    except Exception:
                        print(str(item))
                else:
                    print(item)
        return 0

    # fallback: JSON serialize (use default=str to handle Paths etc.)
    try:
        print(json.dumps(result, default=str, ensure_ascii=False))
    except Exception:
        # last resort: string representation
        print(str(result))
    return 0


def task(func=None, **options):
    if func is None:
        raise ValueError("scout.task expects a function")

    meta = describe_function(func)
    setattr(func, "__scout_meta__", meta)

    # register globally
    _SCOUT_TASK_REGISTRY.append((func, meta))

    mod = inspect.getmodule(func)
    # If the defining module is executed as a script, defer execution until
    # after the module is fully imported by using an atexit handler. This
    # allows multiple scout.task(...) calls to register multiple functions.
    if mod and getattr(mod, "__name__", None) == "__main__" and not _SCOUT_METADATA_BATCH:
        mod_id = id(mod)
        if mod_id not in _SCOUT_DEFER_REGISTERED:
            _SCOUT_DEFER_REGISTERED.add(mod_id)

            def _scout_run_deferred():
                # if metadata requested, emit all metas
                if "--scout-metadata" in sys.argv:
                    metas = [m for (_f, m) in _SCOUT_TASK_REGISTRY]
                    print(json.dumps(metas))
                    return

                # Determine if user requested help
                has_help = any(a in ("-h", "--help") for a in sys.argv[1:])

                # Determine function to run: optional first positional arg
                args = sys.argv[1:]
                func_name = None
                if len(args) >= 1 and not args[0].startswith("-"):
                    func_name = args[0]
                    # do not pop yet; if running we will pop below

                # If user requested help, show the help for the selected task and exit
                if has_help:
                    # choose meta
                    chosen_meta = None
                    if func_name:
                        for _f, m in _SCOUT_TASK_REGISTRY:
                            if m.get('name') == func_name:
                                chosen_meta = m
                                break
                        if chosen_meta is None:
                            print(f"[scout.task] Unknown task '{func_name}'", file=sys.stderr)
                            import os
                            os._exit(2)
                    else:
                        chosen_meta = _SCOUT_TASK_REGISTRY[-1][1]

                    # Build a parser for that function and print help
                    parser = argparse.ArgumentParser(prog=f"{Path(sys.argv[0]).name} {chosen_meta.get('name')}", description=chosen_meta.get('description') or "")
                    for p in chosen_meta['params']:
                        _add_arg_for_param(parser, p)
                    parser.add_argument("--scout-output", default=None, help="Optional output file path for the result")
                    parser.print_help()
                    try:
                        sys.stdout.flush()
                    except Exception:
                        pass
                    try:
                        sys.stderr.flush()
                    except Exception:
                        pass
                    import os
                    os._exit(0)

                chosen = None
                if func_name:
                    for f, m in _SCOUT_TASK_REGISTRY:
                        if m.get('name') == func_name:
                            chosen = (f, m)
                            break
                    if chosen is None:
                        print(f"[scout.task] Unknown task '{func_name}'", file=sys.stderr)
                        sys.exit(2)
                else:
                    # default: last registered task
                    chosen = _SCOUT_TASK_REGISTRY[-1]

                try:
                    # if a function name was provided as first positional arg, remove it
                    if func_name and len(sys.argv) > 1:
                        # remove the first positional argument (function name)
                        sys.argv.pop(1)

                    error_file = None
                    if "--scout-error-file" in sys.argv:
                        error_index = sys.argv.index("--scout-error-file")
                        if error_index + 1 < len(sys.argv):
                            error_file = sys.argv[error_index + 1]
                            del sys.argv[error_index:error_index + 2]

                    code = _run_cli(chosen[0], chosen[1], error_file=error_file)
                    try:
                        sys.stdout.flush()
                    except Exception:
                        pass
                    try:
                        sys.stderr.flush()
                    except Exception:
                        pass
                    import os
                    os._exit(code)
                except SystemExit as e:
                    # argparse may trigger SystemExit (e.g. --help). Ensure we exit quietly.
                    try:
                        import os
                        code = e.code if isinstance(e.code, int) else 0
                        os._exit(code)
                    except Exception:
                        pass
                except Exception as e:
                    print(f"[scout.task] Error: {e}", file=sys.stderr)
                    traceback.print_exc(file=sys.stderr)
                    import os
                    os._exit(1)

            atexit.register(_scout_run_deferred)

    return func
