require_relative '../../python'
require 'shellwords'
module PythonWorkflow

  def self.read_python_metadata(file)
    out = ScoutPython.run_file file, '--scout-metadata'
    raise "Error getting metadata from #{file}: #{err}" unless out.exit_status == 0
    JSON.parse(out.read)
  end

  def self.map_returns(py_type)
    case py_type
    when 'string' then :string
    when 'integer' then :integer
    when 'float' then :float
    when 'boolean' then :boolean
    when 'binary' then :binary
    when 'path' then :string
    else
      :string
    end
  end

  def self.map_param(p)
    desc = p['help'] || ""
    default = p['default']
    required = p['required'] ? true : false

    ruby_type =
      case p['type']
      when 'string' then :string
      when 'integer' then :integer
      when 'float'   then :float
      when 'boolean' then :boolean
      when 'binary'  then :binary
      when 'path'    then :file
      else
        if p['type'].start_with?('list[')
          subtype = p['type'][5..-2]
          ruby_sub = case subtype
                     when 'path' then :file_array
                     else :array
                     end
          ruby_sub
        else
          :string
        end
      end

    options = {}
    options[:required] = true if required

    { name: p['name'], type: ruby_type, desc: desc, default: default, options: options }
  end

  def python_task(task_sym, file: nil, returns: nil, extension: nil, desc: nil)
    name = task_sym.to_s
    file ||= File.join(python_task_dir, "#{name}.py")
    raise "Python task file not found: #{file}" unless File.exist?(file)

    meta = PythonWorkflow.read_python_metadata(file)
    meta['returns'] = returns.to_s if returns
    task_desc = desc || meta['description']

    ruby_returns = PythonWorkflow.map_returns(meta['returns'])
    ruby_inputs  = meta['params'].map { |p| PythonWorkflow.map_param(p) }

    ruby_inputs.each do |inp|
      input(inp[:name].to_sym, inp[:type], inp[:desc], inp[:default], inp[:options] || {})
    end

    self.desc(task_desc) if task_desc && !task_desc.empty?
    self.extension(extension) if extension

    task({ name.to_sym => ruby_returns }) do |*args|
      arg_names = ruby_inputs.map { |i| i[:name] }
      values = {}
      arg_names.each_with_index { |n,i| values[n] = args[i] }

      argv = PythonWorkflow.build_python_argv(meta['params'], values)

      ScoutPython.run_file file, Shellwords.shelljoin(argv)
      #env = { 'PYTHONPATH' => File.expand_path(File.join(Dir.pwd, 'python')) }
      #out, err, status = Open3.capture3(env, PythonWorkflow.python_exec, file, *argv)
      #unless status.success?
      #  raise "Python task #{name} failed (#{status.exitstatus}): #{err}"
      #end
      #out
    end
  end
end
