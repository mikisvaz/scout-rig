require_relative '../../python'
require 'shellwords'
require 'tmpdir'
module PythonWorkflow

  class PythonTaskException < ScoutException
    def initialize(message, python_traceback = nil)
      super(message)
      self.python_traceback = python_traceback if python_traceback
    end

    def python_traceback
      @python_traceback || Array(backtrace).join("\n")
    end

    def python_traceback=(traceback)
      @python_traceback = traceback
      set_backtrace(traceback.lines(chomp: true))
    end

    def self.json_create(data)
      exception = new(data.fetch('m'), data['python_traceback'])
      exception.set_backtrace(data['b']) if data['b']
      exception
    end

    def as_json(*)
      super.merge('python_traceback' => @python_traceback)
    end
  end

  def self.read_python_metadata(file)
    out = ScoutPython.run_file file, '--scout-metadata'
    raise "Error getting metadata from #{file}: #{err}" unless out.exit_status == 0
    JSON.parse(out.read)
  end

  # ScoutCoder: batch mode runs each file with __name__ == '__main__' and
  # collects registrations immediately, but imported modules are shared/cached
  # across files, so task registrations hidden in a shared import may be absent
  # from later files' metadata. Use the default per-file mode when isolation is
  # required.
  def self.read_python_metadata_files(files)
    runner = File.expand_path('../../../../python/scout/runner.py', __dir__)
    out = ScoutPython.run_file runner, Shellwords.shelljoin(['--scout-metadata-files', *files.map(&:to_s)])
    raise "Error getting metadata for Python task files: #{files.join(', ')}" unless out.exit_status == 0
    JSON.parse(out.read).each_with_object({}) do |entry, result|
      result[File.expand_path(entry.fetch('file'))] = entry.fetch('metadata')
    end
  end

  def self.read_task_error(file)
    payload = JSON.parse(File.read(file))
    return nil unless payload.is_a?(Hash) && payload.keys.sort == %w[error message traceback version]
    return nil unless payload['version'].instance_of?(Integer) && payload['version'] == 1
    return nil unless payload['error'] == 'ScoutTaskError'
    return nil unless payload['message'].is_a?(String) && payload['traceback'].is_a?(String)

    PythonTaskException.new(payload['message'], payload['traceback'])
  rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES, Errno::EISDIR
    nil
  end

  def self.map_returns(py_type)
    case py_type
    when nil then :string
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

  def python_task(task_sym, file: nil, returns: nil, extension: nil, desc: nil, metadata: nil)
    name = task_sym.to_s
    file ||= Open.readpath(python_task_dir[name].find_with_extension('py'))
    raise "Python task file not found: #{file}" unless File.exist?(file)

    metas = metadata || PythonWorkflow.read_python_metadata(file)
    register_python_task_metadata(file, metas, returns: returns, extension: extension, desc: desc)
  end

  def register_python_task_metadata(file, metas, returns: nil, extension: nil, desc: nil)
    metas = [metas] unless Array === metas

    metas.each do |meta|
      meta['returns'] = returns.to_s if returns
      task_desc = desc || meta['description']

      ruby_returns = PythonWorkflow.map_returns(meta['returns'])
      ruby_inputs = meta['params'].nil? ? [] : meta['params'].map { |p| PythonWorkflow.map_param(p) }

      ruby_inputs.each do |inp|
        input(inp[:name].to_sym, inp[:type], inp[:desc], inp[:default], inp[:options] || {})
      end

      self.desc(task_desc) if task_desc && !task_desc.empty?
      self.extension(extension) if extension

      task({ meta['name'].to_sym => ruby_returns }) do |*args|
        arg_names = ruby_inputs.map { |i| i[:name] }
        values = {}
        arg_names.each_with_index { |n, i| values[n] = args[i] }

        argv = PythonWorkflow.build_python_argv(meta['params'], values)
        full_argv = [meta['name']] + argv
        output = nil
        Dir.mktmpdir('scout-python-task-') do |protocol_dir|
          protocol_file = File.join(protocol_dir, 'controlled-error.json')
          invocation_argv = full_argv + ['--scout-error-file', protocol_file]
          begin
            output = ScoutPython.run_file file, Shellwords.shelljoin(invocation_argv)
          rescue ProcessFailed
            controlled_error = PythonWorkflow.read_task_error(protocol_file)
            if controlled_error
              controlled_error.set_backtrace(controlled_error.python_traceback.lines(chomp: true))
              raise controlled_error
            end
            raise
          end
        end

        raise "Python task #{meta['name']} failed" unless output.exit_status == 0
        txt = output.read.to_s
        begin
          next JSON.parse(txt)
        rescue JSON::ParserError
          if ruby_returns == :array || ruby_returns == :file_array
            next txt.split("\n").map(&:to_s)
          end
          next txt.strip
        end
      end
    end
  end
end
