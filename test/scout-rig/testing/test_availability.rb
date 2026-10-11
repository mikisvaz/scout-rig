# Focused behavior tests for ScoutRig::Testing::Availability (step 3 of the
# testing-availability plan; see research/testing-availability-baseline.md).
#
# The suite runs on FAKE interpreters alone, so it is green on a machine with
# no python and no R at all. Only the handful of tests that genuinely need a
# real interpreter (a real stdlib import, a real R runtime) are omit-gated.

require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout-rig/testing/availability'

require 'fileutils'
require 'tmpdir'
require 'open3'

class TestScoutRigTestingAvailability < Test::Unit::TestCase
  AVAIL = ScoutRig::Testing::Availability

  ENV_KEYS = %w[PATH PYTHON SCOUT_TEST_PYTHON SCOUT_TEST_RSCRIPT PYTHONHOME PYTHONPATH].freeze

  def setup
    @env_snapshot = ENV_KEYS.each_with_object({}) { |k, h| h[k] = ENV[k] }
    AVAIL.reset!
    # NOTE: scratch lives under Dir.tmpdir, NOT Test::Unit::TestCase.tmpdir:
    # the base test_helper setup/teardown callbacks `Open.rm_rf` that tree,
    # which would delete the fakes mid-test (observed as Errno::ENOENT).
    @scratch = File.join(Dir.tmpdir, "scout-rig-availability-#{$$}-#{rand(1e9).to_i}")
    FileUtils.mkdir_p(@scratch)
    @fakes = []
  end

  def teardown
    ENV_KEYS.each { |k| v = @env_snapshot[k]; v.nil? ? ENV.delete(k) : ENV[k] = v }
    AVAIL.reset!
    FileUtils.rm_rf(@scratch) if File.directory?(@scratch)
  end

  # --- fake interpreter helpers ----------------------------------------

  # Writes a #!/bin/sh fake executable named `name` into the scratch dir and
  # returns its absolute path.
  def fake_executable(name, body)
    path = File.join(@scratch, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
    @fakes << path
    path
  end

  def counter_value(counter)
    File.exist?(counter) ? File.read(counter).to_i : 0
  end

  # A fake python that echoes every probe argument after '-c <source>' to
  # stderr and exits 1: it lets each test observe exactly what the probe
  # passed as module names.
  ARG_ECHO_BODY = 'shift 2; for a in "$@"; do printf "%s\n" "$a" >&2; done; exit 1'.freeze

  # --- Python: runnable present / missing / non-runnable -----------------

  def test_python_runnable_present_when_fake_exits_zero
    exe = fake_executable('python_ok', 'exit 0')
    assert AVAIL.python?(executable: exe)
    assert_nil AVAIL.python_modules_reason(executable: exe)
  end

  def test_python_runnable_output_is_ignored_when_exit_zero
    # Junk on stdout (and stderr) must not turn a success into a failure:
    # the helpers decide on exit status only.
    exe = fake_executable('python_noisy_ok', 'echo "junk on stdout"; echo "junk on stderr" >&2; exit 0')
    assert AVAIL.python?(executable: exe)
    assert_nil AVAIL.python_modules_reason(executable: exe)
  end

  def test_python_non_runnable_when_fake_exits_one_even_silent
    # The exit-1 fake may print nothing: still false.
    exe = fake_executable('python_silent_fail', 'exit 1')
    refute AVAIL.python?(executable: exe)
    reason = AVAIL.python_modules_reason('sys', executable: exe)
    assert_not_nil reason, 'a module probe against a non-runnable interpreter must explain itself'
    assert_includes reason, exe
  end

  def test_python_stderr_marker_lands_in_reason
    exe = fake_executable('python_fail_marker', 'echo "deliberate failure marker" >&2; exit 1')
    refute AVAIL.python?(executable: exe)
    reason = AVAIL.python_modules_reason('sys', executable: exe)
    assert_includes reason, 'deliberate failure marker'
    assert_includes reason, exe
  end

  def test_python_missing_executable_returns_false_never_raises
    exe = File.join(@scratch, 'python_does_not_exist_zz')
    refute File.exist?(exe)
    refute AVAIL.python?(executable: exe)
    reason = AVAIL.python_modules_reason('sys', executable: exe)
    assert_not_nil reason
    assert_match(/could not start|No such file|ENOENT/i, reason)
    assert_includes reason, exe
  end

  # --- Python modules -----------------------------------------------------

  def test_python_modules_missing_module_reason_names_module_and_executable
    exe = fake_executable('python_import_fail', 'echo "definitely_not_a_module_xyz: No module named" >&2; exit 1')
    refute AVAIL.python_modules?('definitely_not_a_module_xyz', executable: exe)
    reason = AVAIL.python_modules_reason('definitely_not_a_module_xyz', executable: exe)
    assert_includes reason, 'definitely_not_a_module_xyz'
    assert_includes reason, exe
  end

  def test_python_modules_real_stdlib_gated
    omit 'no python interpreter available' unless AVAIL.python?
    assert AVAIL.python_modules?('sys', 'os')
    assert_nil AVAIL.python_modules_reason('sys', 'os')
    refute AVAIL.python_modules?('definitely_not_a_module_xyz')
    reason = AVAIL.python_modules_reason('definitely_not_a_module_xyz')
    assert_includes reason, 'definitely_not_a_module_xyz'
  end

  # --- injection safety ---------------------------------------------------

  def test_python_modules_multi_line_name_travels_as_one_name
    # The whole string (embedded newline and all) must travel as ONE argv
    # element: nothing on the second line may execute.
    exe = fake_executable('python_arg_echo', ARG_ECHO_BODY)
    refute AVAIL.python_modules?("sys\nimport os", executable: exe)
    reason = AVAIL.python_modules_reason("sys\nimport os", executable: exe)
    # The reason must report the WHOLE string as one missing module name, not
    # only "sys" as if the newline had split or re-parsed it.
    assert_includes reason, "sys\nimport os"
    assert_includes reason, exe
  end

  def test_python_modules_quote_and_flag_like_names_are_inert
    exe = fake_executable('python_arg_echo2', ARG_ECHO_BODY)
    ["'; import os", '-c', '--version'].each do |weird|
      refute AVAIL.python_modules?(weird, executable: exe), weird.inspect
      reason = AVAIL.python_modules_reason(weird, executable: exe)
      assert_includes reason, weird, weird.inspect
      assert_includes reason, exe, weird.inspect
    end
  end

  # --- R runtime ----------------------------------------------------------

  def test_rscript_runnable_present_when_fake_exits_zero
    exe = fake_executable('Rscript_ok', 'exit 0')
    assert AVAIL.rscript?(executable: exe)
    assert_nil AVAIL.r_packages_reason('base', executable: exe)
  end

  def test_rscript_non_runnable_reports_failure_with_stderr
    exe = fake_executable('Rscript_fail', 'echo "R deliberate failure marker" >&2; exit 1')
    refute AVAIL.rscript?(executable: exe)
    reason = AVAIL.r_packages_reason('base', executable: exe)
    assert_not_nil reason
    assert_includes reason, 'R deliberate failure marker'
    assert_includes reason, exe
  end

  def test_rscript_missing_executable_returns_false_never_raises
    exe = File.join(@scratch, 'Rscript_does_not_exist_zz')
    refute File.exist?(exe)
    refute AVAIL.rscript?(executable: exe)
    reason = AVAIL.r_packages_reason('base', executable: exe)
    assert_not_nil reason
    assert_match(/could not start|No such file|ENOENT/i, reason)
    assert_includes reason, exe
  end

  # --- R packages: loadability not list presence --------------------------

  def test_r_package_missing_reports_missing_name
    # Fake Rscript that plays the probe's contract: prints the missing
    # package name to stdout, exit 1.
    exe = fake_executable('Rscript_missing_pkg', 'echo "nosuchpkgxyz123"; exit 1')
    refute AVAIL.r_packages?('nosuchpkgxyz123', executable: exe)
    reason = AVAIL.r_packages_reason('nosuchpkgxyz123', executable: exe)
    assert_includes reason, 'nosuchpkgxyz123'
    assert_includes reason, exe
  end

  def test_r_package_installed_but_not_loadable_reports_unavailable
    # "Installed but not loadable": the fake acknowledges the package exists
    # (prints a list-presence line) but reports a load failure and exits 1.
    # Availability must follow loadability, not list presence.
    exe = fake_executable(
      'Rscript_not_loadable',
      'echo "error: package or namespace load failed" >&2; exit 1'
    )
    refute AVAIL.r_packages?('stats', executable: exe)
    reason = AVAIL.r_packages_reason('stats', executable: exe)
    assert_not_nil reason
    assert_includes reason, 'error: package or namespace load failed'
    assert_includes reason, exe
    # Loadability, not list presence: the fake never printed a "missing
    # packages" line to stdout, so the reason must not claim one.
    refute_includes reason, 'missing R packages'
  end

  def test_r_packages_real_runtime_gated
    omit 'no Rscript available' unless AVAIL.rscript?
    assert AVAIL.r_packages?('base')
    assert_nil AVAIL.r_packages_reason('base')
    refute AVAIL.r_packages?('nosuchpkgxyz123')
    reason = AVAIL.r_packages_reason('nosuchpkgxyz123')
    assert_includes reason, 'nosuchpkgxyz123'
  end

  def test_r_injection_safety
    # An R analog of the Python injection checks: the whole name (newline
    # included) must be passed through as data, never re-parsed as R source.
    exe = fake_executable('Rscript_arg_echo', ARG_ECHO_BODY)
    weird = "a\nquit(status=0)"
    refute AVAIL.r_packages?(weird, executable: exe)
    reason = AVAIL.r_packages_reason(weird, executable: exe)
    assert_includes reason, weird
    assert_includes reason, exe
  end

  # --- timeout ------------------------------------------------------------

  def test_hanging_python_is_bounded_and_reports_timeout
    exe = fake_executable('python_hang', 'sleep 30')
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    refute AVAIL.python?(executable: exe, timeout: 1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert elapsed < 8, "probe took #{elapsed}s; the 1s timeout was not enforced"

    reason = AVAIL.python_modules_reason('sys', executable: exe, timeout: 1)
    assert_includes reason, 'timed out'
    assert_includes reason, exe
  end

  def test_timeout_is_not_memoized
    counter = File.join(@scratch, 'hang_counter')
    exe = fake_executable(
      'python_hang_count',
      "n=$(cat #{counter} 2>/dev/null || echo 0); echo $((n+1)) > #{counter}; sleep 30"
    )
    AVAIL.python_modules?('sys', executable: exe, timeout: 1)
    AVAIL.python_modules?('sys', executable: exe, timeout: 1)
    assert_equal 2, counter_value(counter), 'a timeout must not be memoized; both calls must run'
  end

  # --- launch error -------------------------------------------------------

  def test_launch_error_clean_handling_no_raise
    exe = File.join(@scratch, 'missing_dir_zz', 'python')
    refute AVAIL.python?(executable: exe)
    refute AVAIL.python_modules?('sys', executable: exe)
    reason = AVAIL.r_packages_reason('base', executable: exe)
    assert_not_nil reason
    assert_includes reason, exe
  end

  # --- selection precedence ------------------------------------------------

  def test_embedded_route_honors_env_python_and_agreement_yields_nil_divergence
    fake = fake_executable('python_env', 'exit 0')
    bin = File.join(@scratch, 'bin_env')
    FileUtils.mkdir_p(bin)
    %w[python python3].each { |n| File.symlink(fake, File.join(bin, n)) }
    ENV['PYTHON'] = fake
    ENV['PATH'] = "#{bin}:#{ENV['PATH']}"
    AVAIL.reset!

    assert_equal fake, AVAIL.embedded_python
    assert_equal 'python', AVAIL.subprocess_python
    assert AVAIL.python?(route: :embedded)
    assert_nil AVAIL.python_routes_divergence_reason
  end

  def test_scout_test_python_overrides_route_default_and_executable_overrides_all
    default_fake = fake_executable('python_default', 'exit 0')
    pin_counter = File.join(@scratch, 'pin_counter')
    # Sanity probe (no module args) exits 0; a module probe fails like an
    # empty interpreter, so the reason distinguishes WHICH fake ran.
    pin_counter_fake = fake_executable(
      'python_pin',
      "n=$(cat #{pin_counter} 2>/dev/null || echo 0); echo $((n+1)) > #{pin_counter}; " \
      'shift 2; if [ "$#" -eq 0 ]; then exit 0; else echo "import failed" >&2; exit 1; fi'
    )
    explicit_fake = selective_python('python_explicit', 'sys')

    bin = File.join(@scratch, 'bin_pin')
    FileUtils.mkdir_p(bin)
    File.symlink(default_fake, File.join(bin, 'python'))
    ENV['PATH'] = "#{bin}:#{ENV['PATH']}"
    AVAIL.reset!
    assert AVAIL.python?, 'route default (PATH python) should work first'

    # SCOUT_TEST_PYTHON beats the route default: the pinned fake is the one
    # that runs. The counting pin proves WHICH fake executed; the reason for a
    # failing module probe must name the pin, never the route default.
    ENV['SCOUT_TEST_PYTHON'] = pin_counter_fake
    AVAIL.reset!
    assert AVAIL.python?
    reason = AVAIL.python_modules_reason('nosuch_zz')
    assert_not_nil reason
    assert_includes reason, pin_counter_fake
    refute_includes reason, default_fake
    assert_equal 2, counter_value(pin_counter), 'python? + module probe = exactly two pin runs'

    # explicit executable: beats the pin
    ENV['SCOUT_TEST_PYTHON'] = pin_counter_fake
    assert AVAIL.python?(executable: explicit_fake)
    reason = AVAIL.python_modules_reason('nosuch_zz', executable: explicit_fake)
    assert_not_nil reason
    assert_includes reason, explicit_fake
    refute_includes reason, pin_counter_fake
    assert_equal 2, counter_value(pin_counter), 'an explicit executable must bypass the pin entirely'
  end

  def test_divergence_reason_non_nil_when_routes_disagree
    env_fake = fake_executable('python_div_env', 'exit 0')
    path_fake = fake_executable('python_div_path', 'exit 0')
    bin = File.join(@scratch, 'bin_div')
    FileUtils.mkdir_p(bin)
    %w[python python3].each { |n| File.symlink(path_fake, File.join(bin, n)) }
    ENV['PYTHON'] = env_fake
    ENV['PATH'] = "#{bin}:#{ENV['PATH']}"
    AVAIL.reset!

    assert_equal env_fake, AVAIL.embedded_python
    assert_equal 'python', AVAIL.subprocess_python
    reason = AVAIL.python_routes_divergence_reason
    assert_not_nil reason
    assert_includes reason, 'embedded'
    assert_includes reason, 'subprocess'
    assert_match(/ENV\[.PYTHON.\]|PATH/, reason)
  end

  def test_resolution_helpers_never_run_the_interpreter
    # Pure resolution: a python fake that would fail hard if executed must
    # not be executed by the resolution helpers.
    ENV['PYTHON'] = nil
    fake = fake_executable('python_resolution', 'exit 42')
    bin = File.join(@scratch, 'bin_res')
    FileUtils.mkdir_p(bin)
    File.symlink(fake, File.join(bin, 'python3'))
    ENV['PATH'] = bin.to_s
    AVAIL.reset!

    assert_equal 'python3', AVAIL.embedded_python
    # No `python` (only python3) in this PATH, so the subprocess route
    # resolves to nil - the route cannot run anything at all.
    assert_nil AVAIL.subprocess_python
    # And nothing was executed: the fake would have exited 42, which nothing
    # records (no counter, no marker), and no probe was run.
    assert !File.exist?(File.join(@scratch, 'resolution_ran_marker')), 'resolution helpers must not execute the interpreter'
  end

  def test_subprocess_python_resolves_the_literal_python_when_present
    fake = fake_executable('python_res_sub', 'exit 42')
    bin = File.join(@scratch, 'bin_res2')
    FileUtils.mkdir_p(bin)
    File.symlink(fake, File.join(bin, 'python'))
    ENV['PATH'] = "#{bin}:#{ENV['PATH']}"
    AVAIL.reset!

    assert_equal 'python', AVAIL.subprocess_python
    assert !File.exist?(File.join(@scratch, 'resolution_ran_marker')), 'resolution helpers must not execute the interpreter'
  end

  # --- memoization ---------------------------------------------------------

  def test_memoization_same_key_does_not_rerun
    counter = File.join(@scratch, 'memo_counter')
    exe = counting_python('python_count', counter)
    assert AVAIL.python_modules?('sys', executable: exe)
    assert_equal 1, counter_value(counter)
    assert AVAIL.python_modules?('sys', executable: exe)
    assert_equal 1, counter_value(counter), 'identical call must be served from memo'
  end

  def test_reset_re_runs_the_probe
    counter = File.join(@scratch, 'reset_counter')
    exe = counting_python('python_count_reset', counter)
    assert AVAIL.python_modules?('sys', executable: exe)
    assert_equal 1, counter_value(counter)
    AVAIL.reset!
    assert AVAIL.python_modules?('sys', executable: exe)
    assert_equal 2, counter_value(counter), 'reset! must clear memoization'
  end

  def test_memo_keys_are_sensitive_to_names_timeout_and_executable
    counter = File.join(@scratch, 'keys_counter')
    exe = counting_python('python_count_keys', counter)
    exe2 = counting_python('python_count_keys2', counter)

    AVAIL.python_modules?('sys', executable: exe)
    assert_equal 1, counter_value(counter)
    AVAIL.python_modules?('os', executable: exe) # different module list -> new key
    assert_equal 2, counter_value(counter)
    AVAIL.python_modules?('sys', executable: exe, timeout: 60) # different timeout (not DEFAULT_TIMEOUT=30) -> new key
    assert_equal 3, counter_value(counter)
    AVAIL.python_modules?('sys', executable: exe2) # different executable -> new key
    assert_equal 4, counter_value(counter)
    AVAIL.python_modules?('sys', executable: exe) # same key again -> memo
    assert_equal 4, counter_value(counter)
  end

  # --- unknown route -------------------------------------------------------

  def test_unknown_route_raises_argument_error
    assert_raise(ArgumentError) { AVAIL.python?(route: :bogus) }
    assert_raise(ArgumentError) { AVAIL.python_modules?('sys', route: :bogus) }
    assert_raise(ArgumentError) { AVAIL.python_modules_reason('sys', route: :bogus) }
  end

  # --- mixin ----------------------------------------------------------------

  def test_mixin_exposes_helpers_as_instance_methods
    object = Object.new
    object.extend(ScoutRig::Testing::Helpers)
    exe = selective_python('python_mixin', 'sys|os')
    assert object.python?(executable: exe)
    assert_nil object.python_modules_reason('sys', executable: exe)
    refute object.python_modules?('nosuch_zz', executable: exe)
    reason = object.python_modules_reason('nosuch_zz', executable: exe)
    assert_includes reason, exe
  end

  # --- isolation: requiring the library must not load production code -------

  def test_require_does_not_load_pycall_or_production_entry
    probe = <<~RUBY
      require 'scout-rig/testing/availability'
      require 'json'
      require 'json'
      puts({
        pycall: (defined?(PyCall) || 'nil').to_s,
        scout_rig: (defined?(ScoutRig) || 'nil').to_s,
        scout_python: (defined?(ScoutPython) || 'nil').to_s,
        production: $LOADED_FEATURES.grep(%r{scout/python\\.rb$|scout-rig\\.rb$}).inspect
      }.to_json)
    RUBY
    stdout, stderr, status = run_isolated_ruby_full(probe)
    require 'json'
    assert status.success?, "isolated probe failed: #{stderr}"
    assert !stdout.strip.empty?, "isolated probe printed nothing: #{stderr}"
    loaded = JSON.parse(stdout)
    assert_equal 'nil', loaded['pycall'], 'PyCall must not load'
    %w[scout_rig].each do |key|
      next if loaded[key] == 'expression' # Ruby 3.5+ reports autoload-triggered modules differently
      assert_equal 'constant', loaded[key], "#{key} must load"
    end
    assert_equal 'nil', loaded['scout_python'], 'ScoutPython must not load'
    assert_equal '[]', loaded['production'], 'no production entry may be loaded'
  end

  private

  # A fake python whose "stdlib" is exactly `ok` (a shell case pattern or
  # alternation like 'sys|os'): the sanity probe (no module args) succeeds,
  # any module outside the allowlist fails to import. This is the minimal
  # faithful stand-in for a real interpreter.
  def selective_python(name, ok)
    fake_executable(
      name,
      'shift 2; for a in "$@"; do case "$a" in ' \
      "#{ok}) ;; *) echo \"No module named '$a'\" >&2; exit 1;; esac; done; exit 0"
    )
  end

  def counting_python(name, counter)
    fake_executable(
      name,
      "n=$(cat #{counter} 2>/dev/null || echo 0); echo $((n+1)) > #{counter}; exit 0"
    )
  end

  # Runs a snippet in a FRESH ruby process with the repo's lib on the path,
  # so memoization and load state cannot leak from this process.
  def run_isolated_ruby_full(code)
    # repo/lib: test/scout-rig/testing/test_availability.rb is three levels
    # below test/, and lib/ sits beside test/.
    paths = [File.expand_path('../../../lib', __dir__)]
    # scout-essentials lib, taken from where THIS process actually loaded
    # scout/testing/availability from (the released gem predates the file, so
    # the load path entry cannot be assumed).
    loaded = $LOADED_FEATURES.grep(%r{scout/testing/availability\.rb$}).first
    paths << File.dirname(File.dirname(File.dirname(loaded))) if loaded
    # The child runs WITHOUT this file's -Itest flag and without the ambient
    # RUBYOPT load paths, so only these two libs (plus default gems) can be
    # required: that is what makes the no-production-load assertion honest.
    args = paths.flat_map { |p| ['-I', p] }
    Open3.capture3({ 'RUBYOPT' => nil }, RbConfig.ruby, *args, '-e', code)
  end

  def run_isolated_ruby(code)
    run_isolated_ruby_full(code).first
  end
end
