import argparse
import inspect
import json
import sys
from pathlib import Path
from typing import get_origin, get_args, Union, List
import atexit

__all__ = ["task", "describe_function"]

# registry to hold tasks defined via scout.task in a module
_SCOUT_TASK_REGISTRY = []  # list of (func, meta)
_SCOUT_DEFER_REGISTERED = set()


def _python_type_to_string(ann) -> str:
    if ann is inspect._empty:
        return "string"
    origin = get_origin(ann)
    args = get_args(ann)

    if origin is Union:
        non_none = [a for a in args if a is not type(None)]
        if len(non_none) == 1:
            return _python_type_to_string(non_none[0])
        return "string"

    if origin in (list, List):
        subtype = "string"
        if args:
            subtype = _python_type_to_string(args[0])
        return f"list[{subtype}]"

    if ann is Path:
        return "path"

    if ann in (str, bytes):
        return "string" if ann is str else "binary"
    if ann is int:
        return "integer"
    if ann is float:
        return "float"
    if ann is bool:
        return "boolean"

    return "string"


def _required_from_default(default_val, ann) -> bool:
    if default_val is not inspect._empty:
        return False
    origin = get_origin(ann)
    args = get_args(ann)
    if origin is Union and type(None) in args:
        return False
    return True


def _parse_numpy_params(doc: str) -> dict:
    if not doc:
        return {}
    lines = doc.splitlines()
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


def describe_function(func) -> dict:
    sig = inspect.signature(func)
    doc = inspect.getdoc(func) or ""
    params_doc = _parse_numpy_params(doc)

    ret_type = _python_type_to_string(sig.return_annotation)
    description = doc.split("\n\n", 1)[0] if doc else ""

    params = []
    for name, p in sig.parameters.items():
        p_type = _python_type_to_string(p.annotation)
        default = None if p.default is inspect._empty else p.default
        required = _required_from_default(p.default, p.annotation)
        help_text = params_doc.get(name, "")
        params.append({
            "name": name,
            "type": p_type,
            "required": required,
            "default": default,
            "help": help_text,
        })

    return {
        "name": func.__name__,
        "description": description,
        "returns": ret_type,
        "params": params,
    }


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
            py_caster = lambda s: str(Path(s))
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
        py_caster = lambda s: str(Path(s))

    parser.add_argument(flag, type=py_caster, required=required, default=default, help=help_text)


def _write_output(out_path: str, data):
    path = Path(out_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, (bytes, bytearray)):
        path.write_bytes(data)
    else:
        path.write_text(str(data))


def _run_cli(func, meta: dict):
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

    result = func(**kwargs)

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
    if mod and getattr(mod, "__name__", None) == "__main__":
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

                    code = _run_cli(chosen[0], chosen[1])
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
                    import os
                    os._exit(1)

            atexit.register(_scout_run_deferred)

    return func
