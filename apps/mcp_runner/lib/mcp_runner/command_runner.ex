defmodule McpRunner.CommandRunner do
  @moduledoc """
  Runs fixed developer commands with bounded output and GNU timeout.

  GNU timeout's default mode signals the command's process group: first TERM,
  then KILL after a grace period. Processes that deliberately detach into a
  different process group are not covered. This is not an OS sandbox.
  """

  alias McpRunner.BoundedOutput

  @output_limit 30_000
  @kill_grace_seconds 5

  @type result :: {:ok, map()} | {:error, String.t()}

  @spec run(String.t(), [String.t()], String.t(), number(), number()) :: result()
  def run(program, arguments, directory, seconds, kill_grace_seconds \\ @kill_grace_seconds)
      when is_binary(program) and is_list(arguments) and is_binary(directory) and
             is_number(seconds) and seconds > 0 and is_number(kill_grace_seconds) and
             kill_grace_seconds > 0 do
    with {:ok, timeout} <- executable("timeout"),
         {:ok, command} <- executable(program) do
      {output, exit_status} =
        System.cmd(
          timeout,
          ["--signal=TERM", "--kill-after=#{kill_grace_seconds}s", "#{seconds}s", command | arguments],
          cd: directory,
          stderr_to_stdout: true,
          into: BoundedOutput.new(@output_limit)
        )

      # GNU timeout returns 124 on expiry, or 137 if KILL escalation occurs.
      # An ordinary command can also exit 124/137, so this is an indication,
      # not an independently verified cause of termination.
      {:ok,
       %{
         exit_status: exit_status,
         timed_out: exit_status in [124, 137],
         output: BoundedOutput.text(output)
       }}
    end
  rescue
    error -> {:error, "Command failed: #{Exception.message(error)}"}
  end

  defp executable(name) do
    case System.find_executable(name) do
      nil -> {:error, "Required executable not found: #{name}"}
      path -> {:ok, path}
    end
  end
end
