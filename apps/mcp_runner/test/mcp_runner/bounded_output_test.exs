defmodule McpRunner.BoundedOutputTest do
  use ExUnit.Case, async: true

  alias McpRunner.BoundedOutput

  test "collects at most the configured byte count" do
    result = Enum.into(["abcd", "efgh", "ijkl"], BoundedOutput.new(6))

    assert result.data == "abcdef"
    assert result.truncated
    assert BoundedOutput.text(result) == "abcdef\n[Output truncated]"
  end

  test "does not label output truncated when exactly at the cap" do
    result = Enum.into(["ab", "cd"], BoundedOutput.new(4))

    refute result.truncated
    assert BoundedOutput.text(result) == "abcd"
  end

  test "converts partial UTF-8 at the byte limit into valid text" do
    result = Enum.into(["a", <<0xC3, 0xA9>>], BoundedOutput.new(2))

    assert result.truncated
    assert BoundedOutput.text(result) == "a�\n[Output truncated]"
  end

  test "System.cmd can write into the bounded collector" do
    {output, status} = System.cmd("printf", ["0123456789"], into: BoundedOutput.new(4))

    assert status == 0
    assert output.data == "0123"
    assert BoundedOutput.text(output) == "0123\n[Output truncated]"
  end
end
