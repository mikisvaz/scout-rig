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
    when 'list', 'array' then :array
    else
      if py_type.start_with?("list[")
        :array
      else
        :string
      end
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
    file ||= python_task_dir[name].find_with_extension('py')
    raise "Python task file not found: #{file}" unless File.exist?(file)

    metas = PythonWorkflow.read_python_metadata(file)
    metas = [metas] unless Array === metas

    # For each function defined in the python file, register a workflow task
    metas.each do |meta|
      meta['returns'] = returns.to_s if returns
      task_desc = desc || meta['description']

      ruby_returns = PythonWorkflow.map_returns(meta['returns'])
      ruby_inputs  = meta['params'].map { |p| PythonWorkflow.map_param(p) }

      ruby_inputs.each do |inp|
        input(inp[:name].to_sym, inp[:type], inp[:desc], inp[:default], inp[:options] || {})
      end

      self.desc(task_desc) if task_desc && !task_desc.empty?
      self.extension(extension) if extension

      task({ meta['name'].to_sym => ruby_returns }) do |*args|
        arg_names = ruby_inputs.map { |i| i[:name] }
        values = {}
        arg_names.each_with_index { |n,i| values[n] = args[i] }

        argv = PythonWorkflow.build_python_argv(meta['params'], values)
        # prefix with function name so the python script runs the desired function
        full_argv = [meta['name']] + argv

        out = ScoutPython.run_file file, Shellwords.shelljoin(full_argv)
        # out is expected to respond to exit_status and read
        raise "Python task #{meta['name']} failed" unless out.exit_status == 0
        txt = out.read.to_s
        # try JSON
        begin
          next JSON.parse(txt)
        rescue JSON::ParserError
          # not JSON; for list returns, split by newline
          if ruby_returns == :array || ruby_returns == :file_array
            next txt.split("\n").map(&:to_s)
          end
          next txt.strip
        end
      end
    end
  end
end
