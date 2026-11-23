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
    raise "Error getting metadata from #{file}" unless out.exit_status == 0
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

  # Python annotation -> Scout input type:
  #   string  -> :string    integer -> :integer    float -> :float
  #   boolean -> :boolean   binary  -> :binary     path  -> :file
  #   list[subtype] -> :array (subtype path -> :file_array)
  # Optional[X] / X | None and Annotated[X, ...] map like their inner type;
  # required-ness comes from the Python default, not the annotation.
  #
  # literal_strings mirrors the workflow's python_literal_strings flag: when
  # true a `str` parameter's Scout input carries :noload, so Scout's input
  # layer (Task.format_input) no longer reads a String naming an existing
  # file into its contents and the literal path reaches Python. Only the
  # string->:string mapping gets :noload; :file/:file_array semantics are
  # already "filename" and are unchanged.
  def self.map_param(p, literal_strings: false)
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
    options[:noload] = true if literal_strings && p['type'] == 'string'

    { name: p['name'], type: ruby_type, desc: desc, default: default, options: options }
  end

  # Effective input contract for one Python parameter, documenting both the
  # Python declaration and the Scout input it produces.
  def self.input_contract(p, literal_strings: false)
    subtype = p['type'].start_with?('list[') ? p['type'][5..-2] : nil
    mapped = map_param(p, literal_strings: literal_strings)
    options = mapped[:options] || {}
    behavior =
      case mapped[:type]
      when :file then 'filename'
      when :file_array then 'list of filenames'
      when :array then 'list of strings'
      when :string then literal_strings ? 'literal text' : 'text or loaded file contents'
      else 'value'
      end
    {
      'name' => p['name'],
      'python_annotation' => p['annotation'],
      'python_type' => p['type'],
      'scout_type' => mapped[:type],
      'required' => p['required'] ? true : false,
      'default' => p['default'],
      'help' => p['help'] || '',
      'behavior' => behavior,
      'flags' => {
        'python_flag' => "--#{p['name']}",
        'nargs' => p['type'].start_with?('list[') ? '+' : nil,
        'elem_type' => subtype,
        'noload' => options[:noload] ? true : nil
      }.compact
    }
  end

  def python_task(task_sym = nil, file: nil, returns: nil, extension: nil, desc: nil, metadata: nil)
    name = task_sym ? task_sym.to_s : nil
    file ||= name && Open.readpath(python_task_dir[name].find_with_extension('py'))
    raise "Python task file not found: #{file}" unless File.exist?(file)

    metas = metadata || PythonWorkflow.read_python_metadata(file)
    register_python_task_metadata(file, metas, returns: returns, extension: extension, desc: desc)
  end

  # Whether a task-object block file is one of ours: a task registered by
  # this codebase (task.rb defines the only Python task blocks). Live-task
  # provenance is the single ownership signal — the tracking map holds
  # names, not task objects.
  private def owns_task_definition?(file)
    # Same file under any spelling (dotted relative, symlink, vendored copy):
    # realpath collapses both, and missing files fall back to expand_path so a
    # stale source_location still compares rather than raising.
    ours = File.realpath(__FILE__) rescue File.expand_path(__FILE__)
    theirs = File.realpath(file) rescue File.expand_path(file)
    theirs == ours
  end

  # Validate exported-task metadata before any DSL side effect. The same
  # Python file may be re-registered (that replaces its entry); a task name
  # already exported by a different file is a conflict, and a name already
  # held by a native (Ruby-defined) task is rejected rather than silently
  # shadowed.
  def validate_python_task_metadata(file, metas, skip_cross_file: false)
    raise "No tasks exported by #{file}" if metas.empty?

    metas.each_with_index do |meta, i|
      next if Hash === meta
      raise "Malformed task metadata at position #{i} in #{file}: expected a Hash, got #{meta.class}"
    end

    metas.each do |meta|
      raise "Malformed task metadata in #{file}: missing 'name' in #{meta.inspect}" if meta['name'].nil? || meta['name'].to_s.empty?
      raise "Malformed task metadata in #{file}: missing 'params' for task #{meta['name']}" unless meta.key?('params')
      params = meta['params']
      raise "Malformed task metadata in #{file}: 'params' must be a list for task #{meta['name']}, got #{params.class}" unless params.nil? || Array === params
    end

    seen = {}
    metas.each do |meta|
      name = meta['name'].to_s
      raise "Duplicate exported task name #{name} in #{file}" if seen[name]
      seen[name] = true
    end

    unless skip_cross_file
      @python_task_registrations.to_a.each do |other_file, other_registration|
        next if File.expand_path(other_file) == File.expand_path(file)
        other_registration['metas'].each do |meta|
          name = meta['name'].to_s
          raise "Task #{name} in #{file} already registered by #{File.expand_path(other_file)}" if seen[name]
        end
      end
    end

    # A native (Ruby-defined) task already holding one of these names is an
    # explicit conflict: registering would silently shadow it. A name is
    # ours only when the live task object under it is a PythonWorkflow
    # registration — i.e. its block was defined in this file, which is the
    # only place Python task blocks are built.
    metas.map { |meta| meta['name'].to_s }.each do |name|
      existing = tasks[name.to_sym]
      next unless existing
      location = existing.source_location
      next if location && owns_task_definition?(location.first)
      raise "Task name #{name} in #{file} conflicts with a native (Ruby-defined) task; pick another name"
    end
  end


  def register_python_task_metadata(file, metas, returns: nil, extension: nil, desc: nil)
    metas = [metas] unless Array === metas
    validate_python_task_metadata(file, metas)

    # Registration record: per file, the Python metadata plus the
    # registration-time configuration (literal_strings, which cannot be
    # applied after the inputs are built).
    registration = {
      'literal_strings' => python_literal_strings,
      'metas' => metas
    }

    metas.each do |meta|
      meta['returns'] = returns.to_s if returns
      task_desc = desc || meta['description']

      # literal_strings must reach map_param while the input options are
      # being built (noload cannot be applied later). It is fixed at
      # registration time in the record above.
      literal_strings = registration['literal_strings']

      ruby_returns = PythonWorkflow.map_returns(meta['returns'])
      ruby_inputs = meta['params'].nil? ? [] : meta['params'].map { |p| PythonWorkflow.map_param(p, literal_strings: literal_strings) }

      ruby_inputs.each do |inp|
        input(inp[:name].to_sym, inp[:type], inp[:desc], inp[:default], inp[:options] || {})
      end

      self.desc(task_desc) if task_desc && !task_desc.empty?
      effective_extension = meta['extension'] || extension
      self.extension(effective_extension) if effective_extension

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
            output = ScoutPython.run_file file, Shellwords.shelljoin(invocation_argv),
              env: { 'SCOUT_JOB_FILES_DIR' => files_dir.to_s }
          rescue ProcessFailed
            controlled_error = PythonWorkflow.read_task_error(protocol_file)
            if controlled_error
              controlled_error.set_backtrace(controlled_error.python_traceback.lines(chomp: true))
              raise controlled_error
            end
            raise
          end
        end

        txt = output.read.to_s
        if output.exit_status != 0
          stderr_text = (output.stderr.respond_to?(:read) ? output.stderr.read : output.stderr.to_s).to_s
          detail = stderr_text.strip.empty? ? txt.strip : stderr_text.strip
          raise "Python task #{meta['name']} failed with exit status #{output.exit_status}" + (detail.empty? ? '' : ":\n#{detail}")
        end
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

    # Commit the tracking only after every task in the file registered
    # cleanly; a raise leaves the previous record intact.
    (@python_task_registrations ||= {})[File.expand_path(file)] = registration
    metas
  end
end
