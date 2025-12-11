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
        Array(val).each do |x|
          argv << flag
          argv << x.to_s
        end
      elsif ptype == 'boolean'
        if default == true
          argv << "--no-#{name}" unless val
        else
          argv << flag if val
        end
      else
        argv << flag
        argv << val.to_s
      end
    end
    argv
  end
end
