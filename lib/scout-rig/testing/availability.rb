# Opt-in runtime-availability probes for scout-rig test suites (step 2 of
# the testing-availability plan; see research/testing-availability-baseline.md
# and the scout-essentials handoff note it references).
#
# Layering contract: scout-essentials owns the generic primitives (PATH
# lookup, bounded child execution, bounded TCP connect); scout-rig owns the
# interpreter knowledge layered on top. This file adds only that knowledge:
#
#   python? / python_modules? / python_modules_reason
#   rscript? / r_packages? / r_packages_reason  (reference probes only; no
#                                                scout-rig R runtime is
#                                                implied or validated)
#   embedded_python / subprocess_python / python_routes_divergence_reason
#   reset!
#
# It is strictly opt-in: requiring it loads 'scout/testing/availability'
# and nothing else of consequence - no scout-rig production code, no
# ScoutPython, no embedded-Python bridge - and no production or entry file
# may require it back. Tests require it explicitly:
#
#   require 'scout-rig/testing/availability'
#
# Process discipline, delegated to the primitive: every check launches a
# child through Scout::Testing::Availability.run_command (bounded timeout,
# both output streams drained concurrently, launch failure and timeout
# reported on the returned result instead of raised) and decides on the
# REAL exit status, never on output and never on mere PATH existence.
# Module and package names always travel as process arguments to a fixed
# probe source; they are never interpolated into Python or R source, so no
# name can escape a string literal. Nothing here rescues Exception, and the
# only rescue in the file is a StandardError-scoped guard around a
# filesystem resolution race: no SignalException or NoMemoryError can be
# swallowed and cached as "unavailable" - unexpected exceptions propagate
# to the caller.

require 'scout/testing/availability'

module ScoutRig
  module Testing
    module Availability

      # Bounded timeout, in seconds, for every probe. Aligned with
      # Scout::Testing::Availability::DEFAULT_TIMEOUT. Importing a large
      # package (numpy, pandas, torch, ...) is slower than a stdlib import,
      # so every helper takes a `timeout:` keyword (nil means this default)
      # that is cheap to raise; the timeout is part of every memo key, so
      # raising it never replays a stale verdict.
      DEFAULT_TIMEOUT = 30

      # Default execution route probed. :subprocess is what
      # ScoutPython.script, ScoutPython.run_file and python_task actually
      # run today (a literal `python` resolved from PATH; see
      # lib/scout/python/script.rb), so it is the honest default for gating
      # tests. :embedded predicts the interpreter the in-process bridge
      # would pick instead; see embedded_python for exactly what that
      # prediction does and does not promise.
      DEFAULT_ROUTE = :subprocess

      # Routes a Python probe accepts.
      ROUTES = [:subprocess, :embedded].freeze

      # Longest tail of captured child output kept in a reason string, so
      # reasons stay concise and human-actable.
      REASON_TAIL = 400

      # Shared memo store for definitive probe results, and its lock. A
      # constant rather than a module ivar so that the mixin form (include
      # ScoutRig::Testing::Availability, or its Helpers alias) and the
      # module-function form share one cache: an instance-method call would
      # otherwise write ivars on the including object instead of the
      # module. reset! clears it in place; never reassign it.
      MEMO = {}
      MEMO_MUTEX = Mutex.new

      # Sanity probe for a Python interpreter: it must start and exit 0.
      # Output is irrelevant; the exit status is the verdict.
      PYTHON_SANITY_SOURCE = 'import sys'.freeze

      # Fixed import probe (frozen source; module names arrive as argv and
      # are never interpolated into this text). Missing modules, with the
      # exception type and message, are written to stderr - where Python
      # tracebacks belong - and any miss exits 1. The in-source rescue
      # keeps stderr condensed to one line per missing module, so reasons
      # never need traceback surgery. Names are passed as trailing argv
      # after `-c <source>`: everything following `-c <source>` lands in
      # sys.argv verbatim (verified: even names like '-c' or '--version'
      # are not re-parsed as interpreter options), so no name can be
      # swallowed as an option or executed as code.
      PYTHON_MODULES_PROBE = <<~'PY'.freeze
        import importlib
        import sys

        missing = []
        for name in sys.argv[1:]:
            try:
                importlib.import_module(name)
            except Exception as exc:
                missing.append("%s: %s: %s" % (name, type(exc).__name__, exc))
        if missing:
            sys.stderr.write("; ".join(missing) + "\n")
            sys.exit(1)
      PY

      # Sanity probe for an Rscript executable: starts, writes, exits 0.
      RSCRIPT_SANITY_SOURCE = 'cat("ok")'.freeze

      # Fixed namespace probe (frozen source; package names arrive through
      # commandArgs(TRUE), never interpolated). Availability means
      # requireNamespace() LOADS the package - not that its name appears in
      # an installation list. Missing names are printed to stdout (R's cat
      # writes there) and any miss quits with status 1.
      #
      # commandArgs(TRUE) RETAINS the literal '--args' element when Rscript
      # is invoked as `Rscript -e <src> --args pkg...`, so the probe filters
      # it explicitly.
      R_PACKAGES_PROBE = <<~'R'.freeze
        args <- commandArgs(TRUE)
        pkgs <- args[args != "--args"]
        absent <- character(0)
        for (pkg in pkgs) {
          if (!requireNamespace(pkg, quietly = TRUE)) {
            absent <- c(absent, pkg)
          }
        }
        if (length(absent) > 0) {
          cat(paste(absent, collapse = ", "), "\n")
          quit(status = 1)
        }
      R

      # --- Python interpreter and module probes --------------------------------

      # True iff the selected Python executable exists AND runs: the sanity
      # probe is executed and must exit 0. PATH existence alone proves
      # nothing (a broken interpreter or a missing stdlib still shows up on
      # PATH), and output is never consulted.
      #
      # Selection precedence, first match wins (see python_target):
      #   1. the `executable:` keyword (explicit, overrides everything)
      #   2. ENV['SCOUT_TEST_PYTHON'] (test-only pin, see below)
      #   3. the default for `route:` - :subprocess (the default) resolves
      #      subprocess_python, :embedded resolves embedded_python
      def python?(executable: nil, route: DEFAULT_ROUTE, timeout: nil)
        python_runtime_reason(executable: executable, route: route, timeout: timeout).nil?
      end

      # True iff every named module imports under the selected interpreter.
      # Exactly `python_modules_reason(...).nil?`. Symbols are accepted and
      # normalized to strings, so `python_modules?(:torch)` works. An empty
      # module list is vacuously available - but only after an interpreter
      # was actually selected: with no executable resolved, the absent-
      # interpreter reason wins, so an empty ask never masks a missing
      # interpreter.
      def python_modules?(*modules, executable: nil, route: DEFAULT_ROUTE, timeout: nil)
        python_modules_reason(*modules, executable: executable, route: route, timeout: timeout).nil?
      end

      # nil when every named module imports under the selected interpreter;
      # otherwise one concise diagnostic string that includes the resolved
      # executable path, the failing module name(s) and the useful stderr
      # tail - enough for a human to act on. Use it as an omit message when
      # an optional dependency is genuinely absent; never use it to swallow
      # a regression in shipped code.
      def python_modules_reason(*modules, executable: nil, route: DEFAULT_ROUTE, timeout: nil)
        seconds = probe_timeout(timeout)
        target, source = python_target(executable, route)
        return absent_interpreter_reason('Python', 'SCOUT_TEST_PYTHON', source) if target.nil?
        return nil if modules.empty?

        names = modules.map(&:to_s)
        display = resolved_path_or_name(target)
        memoized([:python_modules, display, names.sort, seconds, route]) do
          result = Scout::Testing::Availability.run_command(
            [target, '-c', PYTHON_MODULES_PROBE, *names], timeout: seconds
          )
          if result.success? && result.exit_status == 0
            reason = nil
          else
            reason = python_modules_failure_reason(result, display, names, seconds)
          end
          [reason, definitive?(result)]
        end
      end

      # --- R interpreter and package probes (reference code) -------------------
      #
      # scout-rig has no R execution runtime. These probes report whether an
      # R installation is usable from a test (Rscript runs, packages load);
      # they imply nothing about how scout-rig would execute R, because it
      # does not. There is no `route:` dimension for the same reason.

      # True iff the selected Rscript exists AND runs: the sanity probe is
      # executed and must exit 0. Selection precedence: the `executable:`
      # keyword, then ENV['SCOUT_TEST_RSCRIPT'], then `Rscript` from PATH.
      def rscript?(executable: nil, timeout: nil)
        rscript_runtime_reason(executable: executable, timeout: timeout).nil?
      end

      # True iff every named package loads (requireNamespace, not an
      # installation-list lookup) under the selected Rscript. Exactly
      # `r_packages_reason(...).nil?`; an empty list is vacuously available
      # once an interpreter was actually selected (see python_modules?).
      def r_packages?(*packages, executable: nil, timeout: nil)
        r_packages_reason(*packages, executable: executable, timeout: timeout).nil?
      end

      # nil when every named package loads; otherwise one concise diagnostic
      # string built stdout-first (the probe's missing-package list) and then
      # the stderr tail, prefixed by the resolved executable path.
      def r_packages_reason(*packages, executable: nil, timeout: nil)
        seconds = probe_timeout(timeout)
        target = rscript_target(executable)
        if target.nil?
          return absent_interpreter_reason('R', 'SCOUT_TEST_RSCRIPT',
                                           'Rscript default (Rscript from PATH)')
        end
        return nil if packages.empty?

        names = packages.map(&:to_s)
        display = resolved_path_or_name(target)
        memoized([:r_packages, display, names.sort, seconds]) do
          result = Scout::Testing::Availability.run_command(
            [target, '--vanilla', '-e', R_PACKAGES_PROBE, '--args', *names],
            timeout: seconds
          )
          if result.success? && result.exit_status == 0
            reason = nil
          else
            reason = r_packages_failure_reason(result, display, names, seconds)
          end
          [reason, definitive?(result)]
        end
      end

      # --- Route accessors and divergence ---------------------------------------

      # The interpreter the EMBEDDED route would use, computed WITHOUT
      # initializing the embedded bridge: ENV['PYTHON'] when set (a blank
      # value counts as unset), else the first of python3/python found on
      # PATH. This mirrors the documented choice of the in-process bridge:
      # PyCall.init reads ENV['PYTHON'] and otherwise investigates python3
      # then python from PATH.
      #
      # This is a PREDICTION of that choice, never a validation. It does not
      # prove that the matching native library loads into the Ruby process,
      # it does not run the interpreter at all, and it deliberately does not
      # reproduce the process-environment mutation the real initialization
      # performs (it would export PYTHONHOME; this accessor never touches
      # the environment). Probing route :embedded therefore checks that the
      # predicted interpreter and its modules work as a subprocess - it
      # cannot certify the in-process binding. Returns nil when nothing
      # matches. Unaffected by SCOUT_TEST_PYTHON, which pins probes only.
      #
      # ScoutCoder: the embedded bridge's PATH candidate order (python3
      # before python) is not documented in scout-rig's user docs; it had to
      # be read from the pycall gem (LibPython::Finder::DEFAULT_PYTHON).
      # doc/user/PythonEnvironments.md only says "PATH resolution when PYTHON
      # is unset".
      def embedded_python
        pinned = ENV['PYTHON'].to_s.strip
        return pinned unless pinned.empty?

        %w[python3 python].each do |candidate|
          return candidate if Scout::Testing::Availability.executable?(candidate)
        end
        nil
      end

      # The interpreter the SUBPROCESS route uses today: the literal command
      # `python` resolved from PATH, exactly what ScoutPython.script,
      # ScoutPython.run_file and python_task spawn (ENV['PYTHON'] is never
      # consulted on that route). Returns nil when PATH has no python, which
      # means the route cannot run anything at all. Unaffected by
      # SCOUT_TEST_PYTHON, which pins probes only.
      def subprocess_python
        'python' if Scout::Testing::Availability.executable?('python')
      end

      # nil when both execution routes resolve to the same interpreter;
      # otherwise a short message naming both resolutions, the cause and the
      # limit of what any single probe can tell you. Resolution here is a
      # PATH lookup canonicalized to an absolute real path (symlinks
      # followed), so python3 and python aliasing one binary do not count as
      # divergent.
      #
      # The comparison is between PREDICTED selections: it never initializes
      # the embedded bridge, so it cannot validate that the native binding
      # loads. SCOUT_TEST_PYTHON is deliberately ignored here: a pin
      # overrides probing only, and a pinned probe silently hiding a real
      # production divergence is exactly what this reporter exists to
      # expose.
      def python_routes_divergence_reason
        embedded = embedded_python
        subprocess = subprocess_python
        embedded_path = resolve_interpreter(embedded)
        subprocess_path = resolve_interpreter(subprocess)

        return nil if embedded_path && subprocess_path && embedded_path == subprocess_path

        embedded_description =
          if embedded.nil?
            'nothing (PYTHON is unset and neither python3 nor python is on PATH)'
          else
            "#{embedded} -> #{embedded_path || 'unresolvable'}"
          end
        subprocess_description =
          if subprocess.nil?
            "nothing (no 'python' on PATH, so the subprocess route cannot run at all)"
          else
            "#{subprocess} -> #{subprocess_path || 'unresolvable'}"
          end

        "Python routes diverge: the embedded route would initialize " \
          "#{embedded_description}, while the subprocess route spawns the literal " \
          "'python' from PATH (#{subprocess_description}). Cause: ENV['PYTHON'] " \
          "selects only the embedded route and PATH selects only the subprocess " \
          "route, so the two can silently point at different interpreters; put the " \
          "intended interpreter's bin directory first on PATH (and unset PYTHON) so " \
          "both resolve it. Note that no probe validates both routes: probing one " \
          "route exercises only that route's interpreter and says nothing about the " \
          "other."
      end

      # --- Memoization control ---------------------------------------------------

      # Drop every memoized probe result. Probe keys are built from inputs
      # that are re-resolved on every call (the executable is resolved
      # through the CURRENT SCOUT_TEST_*/PYTHON/PATH before each probe, so a
      # changed environment naturally produces a new key), and reset! is the
      # explicit hygiene hook for test setups that manipulate the
      # environment: call it whenever you change SCOUT_TEST_PYTHON,
      # SCOUT_TEST_RSCRIPT, PATH or ENV['PYTHON'] and want a provably fresh
      # probe. Returns nil.
      def reset!
        MEMO_MUTEX.synchronize { MEMO.clear }
        nil
      end

      # Both call styles are supported and share one implementation and one
      # MEMO store: module functions
      # (ScoutRig::Testing::Availability.python_modules?(:torch)) and an
      # optional mixin, where a test class includes the module (or its
      # Helpers alias below) and calls the helpers directly from test
      # bodies. The helpers above are ordinary instance methods and the
      # module extends itself; the helpers below stay private in both
      # styles.
      extend self

      private

      # SCOUT_TEST_PYTHON / SCOUT_TEST_RSCRIPT versus PYTHON and PATH:
      #
      # - PYTHON (read by the embedded bridge's initialization) and PATH
      #   (used by the literal `python` subprocess spawn) are PRODUCTION
      #   inputs. This module never sets, unsets or otherwise mutates them.
      # - SCOUT_TEST_PYTHON / SCOUT_TEST_RSCRIPT are TEST-ONLY pins. When
      #   set, they OVERRIDE route resolution for probing: every Python
      #   helper probes exactly that interpreter whichever `route:` is
      #   asked for, so a pinned probe cannot detect a route divergence -
      #   ask python_routes_divergence_reason (which ignores the pin) for
      #   that.
      # - They do not change production code: ScoutPython.script / run_file
      #   / python_task keep spawning `python` from PATH and the embedded
      #   bridge keeps reading PYTHON. The reliable environment recipe
      #   remains "put the intended environment's bin directory first on
      #   PATH so both routes resolve the same interpreter"; the pins exist
      #   for suites that must probe one absolute interpreter, and for R,
      #   where no scout-rig route exists at all.
      def python_target(executable, route)
        unless ROUTES.include?(route)
          raise ArgumentError, "unknown route #{route.inspect}; expected :subprocess or :embedded"
        end

        explicit = executable.to_s.strip
        return [explicit, 'executable: keyword'] unless explicit.empty?

        pinned = ENV['SCOUT_TEST_PYTHON'].to_s.strip
        return [pinned, "ENV['SCOUT_TEST_PYTHON']"] unless pinned.empty?

        case route
        when :subprocess
          [subprocess_python, 'route :subprocess default (literal python from PATH)']
        when :embedded
          [embedded_python, 'route :embedded default (PYTHON else python3/python from PATH)']
        end
      end

      def rscript_target(executable)
        explicit = executable.to_s.strip
        return explicit unless explicit.empty?

        pinned = ENV['SCOUT_TEST_RSCRIPT'].to_s.strip
        return pinned unless pinned.empty?

        'Rscript' if Scout::Testing::Availability.executable?('Rscript')
      end

      # nil (or omitted) timeout means DEFAULT_TIMEOUT. The normalized value
      # is used for the launch, the memo key and every reason string, so an
      # explicit `timeout: nil` and an omitted timeout can never diverge.
      def probe_timeout(timeout)
        timeout.nil? ? DEFAULT_TIMEOUT : timeout
      end

      # A run is definitive when the child actually reached an exit status.
      # Success and exit-status failures (missing module, missing package,
      # broken interpreter) say something durable about the selected
      # interpreter and MAY be memoized. A launch error or a timeout says
      # nothing durable - the executable may appear on PATH a moment later,
      # or the import may simply be slow - so those verdicts are returned to
      # the caller but NEVER memoized; an identical later call re-runs the
      # probe. This is the rule that keeps a transient condition from being
      # cached as "unavailable" for the rest of the process.
      #
      # ScoutCoder: whether CommandResult offers a timed_out? predicate had
      # to be probed by hand; the struct exposes the plain `timed_out`
      # member (and `reason`) but no predicate, and the scout-essentials
      # source is the only place that says so.
      def definitive?(result)
        !result.launch_error && !result.timed_out
      end

      def python_runtime_reason(executable: nil, route: DEFAULT_ROUTE, timeout: nil)
        seconds = probe_timeout(timeout)
        target, source = python_target(executable, route)
        return absent_interpreter_reason('Python', 'SCOUT_TEST_PYTHON', source) if target.nil?

        display = resolved_path_or_name(target)
        memoized([:python_runtime, display, seconds, route]) do
          result = Scout::Testing::Availability.run_command(
            [target, '-c', PYTHON_SANITY_SOURCE], timeout: seconds
          )
          if definitive?(result) && result.exit_status == 0
            reason = nil
          elsif result.launch_error
            reason = "#{display}: Python interpreter could not start: #{result.launch_error}"
          elsif result.timed_out
            reason = "#{display}: Python interpreter probe timed out after #{seconds}s; " \
                     'raise the timeout: keyword if startup is legitimately slow'
          else
            detail = [result.stderr, result.stdout].map { |stream| stream.to_s.strip }
                                        .reject(&:empty?).first
            reason = if detail
                       "#{display}: python exited #{result.exit_status} (#{tail(detail)})"
                     else
                       "#{display}: python exited #{result.exit_status}"
                     end
          end
          [reason, definitive?(result)]
        end
      end

      def python_modules_failure_reason(result, display, names, seconds)
        if result.launch_error
          "#{display}: Python probe could not start: #{result.launch_error} " \
            "(modules: #{names.join(', ')})"
        elsif result.timed_out
          "#{display}: Python import probe timed out after #{seconds}s " \
            "(modules: #{names.join(', ')}); raise the timeout: keyword for slow imports"
        else
          detail = result.stderr.to_s.strip
          if detail.empty?
            "#{display}: python exited #{result.exit_status} probing modules: #{names.join(', ')}"
          else
            missing = missing_python_names(detail, names)
            "#{display}: missing Python modules: #{missing.join(', ')} (#{tail(detail)})"
          end
        end
      end

      def rscript_runtime_reason(executable: nil, timeout: nil)
        seconds = probe_timeout(timeout)
        target = rscript_target(executable)
        if target.nil?
          return absent_interpreter_reason('R', 'SCOUT_TEST_RSCRIPT',
                                           'Rscript default (Rscript from PATH)')
        end

        display = resolved_path_or_name(target)
        memoized([:rscript_runtime, display, seconds]) do
          result = Scout::Testing::Availability.run_command(
            [target, '--vanilla', '-e', RSCRIPT_SANITY_SOURCE], timeout: seconds
          )
          if definitive?(result) && result.exit_status == 0
            reason = nil
          elsif result.launch_error
            reason = "#{display}: Rscript could not start: #{result.launch_error}"
          elsif result.timed_out
            reason = "#{display}: Rscript probe timed out after #{seconds}s; " \
                     'raise the timeout: keyword if startup is legitimately slow'
          else
            detail = [result.stderr, result.stdout].map { |stream| stream.to_s.strip }
                                        .reject(&:empty?).first
            reason = if detail
                       "#{display}: Rscript exited #{result.exit_status} (#{tail(detail)})"
                     else
                       "#{display}: Rscript exited #{result.exit_status}"
                     end
          end
          [reason, definitive?(result)]
        end
      end

      def r_packages_failure_reason(result, display, names, seconds)
        if result.launch_error
          "#{display}: Rscript probe could not start: #{result.launch_error} " \
            "(packages: #{names.join(', ')})"
        elsif result.timed_out
          "#{display}: R package probe timed out after #{seconds}s " \
            "(packages: #{names.join(', ')}); raise the timeout: keyword for slow loads"
        else
          missing = result.stdout.to_s.strip
          detail = result.stderr.to_s.strip
          parts = []
          parts << "missing R packages: #{missing}" unless missing.empty?
          parts << tail(detail) unless detail.empty?
          parts << "Rscript exited #{result.exit_status}" if parts.empty?
          "#{display}: #{parts.join('; ')}"
        end
      end

      # Store and return the block's verdict. The block returns
      # [reason_or_nil, definitive]; only definitive verdicts are stored, so
      # a timeout or launch error is recomputed on the next identical call
      # (never cached as unavailability). An exception raised by the probe
      # propagates to the caller and is never cached either. The lock is
      # held across the probe so concurrent test threads do not spawn
      # duplicate children for one key.
      def memoized(key)
        MEMO_MUTEX.synchronize do
          return MEMO[key] if MEMO.key?(key)

          value, definitive = yield
          MEMO[key] = value if definitive
          value
        end
      end

      def absent_interpreter_reason(language, env_var, source)
        "#{language} interpreter not found (#{source}); " \
          "pin one with #{env_var} or the executable: keyword, or fix PATH"
      end

      # The probe writes "name: ExceptionType: message" per missing module,
      # joined by "; ". Recover the names; when anything fails to parse,
      # fall back to the requested list (a superset of the missing ones, so
      # the reason never understates what was asked for).
      def missing_python_names(detail, requested)
        parsed = detail.split('; ').map do |entry|
          match = entry.match(/\A([^:]+): /)
          match && match[1].strip
        end.compact
        parsed.empty? ? requested : parsed
      end

      # Canonical absolute path for an executable name: the file itself when
      # the candidate carries a path separator, else the first PATH hit;
      # symlinks are resolved so aliases of one binary compare equal. nil
      # when nothing resolves. Re-run on every call (never memoized) so a
      # mid-process PATH change re-resolves and produces fresh probe keys.
      # The rescue only covers the race between the existence check and
      # realpath (the file disappearing or a path component turning into a
      # file); it is StandardError-scoped by design and returns nil, the
      # honest answer for a candidate that cannot be resolved.
      def resolve_interpreter(name)
        candidate = name.to_s
        return nil if candidate.strip.empty?

        begin
          if candidate.include?(File::SEPARATOR)
            return File.realpath(candidate) if File.file?(candidate) && File.executable?(candidate)
            return nil
          end

          ENV['PATH'].to_s.split(File::PATH_SEPARATOR).each do |directory|
            next if directory.to_s.empty?

            path = File.join(directory, candidate)
            return File.realpath(path) if File.file?(path) && File.executable?(path)
          end
        rescue StandardError
          nil
        end
      end

      # The resolved absolute path when the name resolves, else the name
      # itself: used both for human-facing reasons and for memo keys.
      def resolved_path_or_name(name)
        resolve_interpreter(name) || name.to_s
      end

      def tail(text)
        string = text.to_s
        return string if string.length <= REASON_TAIL

        '...' + string[-REASON_TAIL..]
      end
    end

    # Optional mixin spelling of the same surface: a test class may either
    # call the module functions or `include ScoutRig::Testing::Helpers`.
    # This is the very same module object (Availability extends itself, so
    # including it mixes in the public helpers), not a second
    # implementation; both spellings therefore share one MEMO store and one
    # code path.
    Helpers = Availability
  end
end
