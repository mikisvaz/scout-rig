require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestPythonWorkflow < Test::Unit::TestCase
  def test_file
    sss 0

    code  =<<-EOF
import scout
from typing import List, Optional

def hello(name: str, excited: bool = False) -> str:
    """
    Greet a user.

    Parameters
    ----------
    name : str
        The name of the person to greet.
    excited : bool, optional
        Whether to add an exclamation mark, by default False.

    Returns
    -------
    str
        A greeting message.
    """
    return f"Hello, {name}{'!' if excited else ''}"

scout.task(hello)
    EOF
    TmpFile.with_file code do |script|
      wf = Module.new do
        extend Workflow
        extend PythonWorkflow

        self.name = 'Greet'

        python_task :hello, file: script
      end

      job = wf.job(:hello, name: 'Miguel')
      assert_equal 'Hello, Miguel', job.run.strip
    end
  end
end

