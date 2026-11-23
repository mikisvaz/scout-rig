module PythonWorkflow
  # Build the Python CLI argv for one invocation.
  #
  # Contract (see doc/user/DefiningPythonTasks.md):
  # - Array values stay one argv word per element; a String value for a list
  #   parameter is split on commas ONLY. Existing files are never silently
  #   read: pass File.readlines(path, chomp: true) yourself when you want
  #   that, or use a Scout :array input whose file semantics are explicit.
  # - Scalar values are passed as written. An empty string is a real value:
  #   `--x ''` is ALWAYS emitted so '' is distinguishable from a missing
  #   input. Only nil is skipped (nil means "not provided").
  def self.build_python_argv(py_params, values)
    argv = []
    py_params.each do |p|
      name = p['name']
      ptype = p['type']
      default = p['default']
      required = p['required']
      val = values[name]

      if val.nil?
        next unless required
        next
      end

      flag = "--#{name}"
      if ptype.start_with?('list[')
        items = python_list_items(val)
        # pass flag once followed by all items (argparse with nargs='+' expects this)
        argv << flag
        items.each do |x|
          argv << x.to_s
        end
      elsif ptype == 'boolean'
        if default == true
          argv << "--no-#{name}" unless val
        else
          argv << flag if val
        end
      else
        # Scalar: always emit the flag, including for '' — an empty string is
        # a real value and must stay distinguishable from a missing input.
        # Only nil (skipped above) means "not provided".
        argv << flag
        argv << val.to_s
      end
    end
    argv
  end

  # A list parameter accepts an Array (one argv word per element, literal) or
  # a String (split on commas, or a single item). Filenames are never
  # reinterpreted as file contents at the bridge.
  def self.python_list_items(val)
    items = []
    if val.is_a?(String)
      if val.include?(',')
        items = val.split(',').map(&:strip)
      else
        items = [val]
      end
    elsif val.respond_to?(:to_ary)
      items = Array(val).map(&:to_s)
    else
      items = [val.to_s]
    end
    items
  end
end
