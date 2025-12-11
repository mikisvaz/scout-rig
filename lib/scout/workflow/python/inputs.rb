module PythonWorkflow
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
        # Accept several input formats for lists:
        # - Ruby Array
        # - Comma-separated string: "a,b,c"
        # - Path to a file: "file.txt" -> read lines
        items = []
        if val.is_a?(String)
          # If file exists, read lines
          if File.exist?(val)
            items = File.readlines(val, chomp: true)
          elsif val.include?(',')
            items = val.split(',').map(&:strip)
          else
            items = [val]
          end
        elsif val.respond_to?(:to_ary)
          items = Array(val).map(&:to_s)
        else
          items = [val.to_s]
        end

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
        # For scalar inputs: if given a file path and the file exists, pass the path
        # as-is (the Python side can decide how to handle it). Keep quoting to
        # preserve spaces when later shell-joining.
        argv << flag
        argv << val.to_s
      end
    end
    argv
  end
end
