require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestPythonWorkflow < Test::Unit::TestCase
  def test_true
    sss 0

    wf = Module.new do
      extend Workflow
      extend PythonWorkflow

      self.name = 'Greet'

      python_task :hello
    end

    job = wf.job(:hello, name: 'Miguel')
    assert_equal 'Hello, Miguel', job.run.strip
  end
end

