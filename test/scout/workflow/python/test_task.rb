require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestPythonWorkflowTask < Test::Unit::TestCase
  def test_load_metadata
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

    sss 0
    TmpFile.with_file code do |task_file|
      res = PythonWorkflow.read_python_metadata task_file
      iii res
    end
  end
end

