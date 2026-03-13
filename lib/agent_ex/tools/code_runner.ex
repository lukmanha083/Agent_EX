defmodule AgentEx.Tools.CodeRunner do
  @moduledoc """
  Local code execution tool — runs code in a subprocess with timeout.

  Works with any model via standard tool calling.
  Supports Python, Elixir, and Bash.
  """

  alias AgentEx.Tool

  @default_timeout 30_000

  @doc "Returns a Tool struct for code execution."
  def tool(opts \\ []) do
    lang = Keyword.get(opts, :lang, :python)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Tool.new(
      name: "code_runner",
      description: "Execute #{lang} code and return stdout output.",
      kind: :write,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "code" => %{"type" => "string", "description" => "Code to execute"}
        },
        "required" => ["code"]
      },
      function: fn args -> execute(args, lang, timeout) end
    )
  end

  defp execute(%{"code" => code}, lang, timeout) do
    {cmd, args} = command_for(lang, code)

    task =
      Task.async(fn ->
        System.cmd(cmd, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, String.trim(output)}

      {:ok, {output, exit_code}} ->
        {:error, "Exit code #{exit_code}: #{String.trim(output)}"}

      nil ->
        {:error, "Execution timed out after #{timeout}ms"}
    end
  end

  defp command_for(:python, code), do: {"python3", ["-c", code]}
  defp command_for(:elixir, code), do: {"elixir", ["-e", code]}
  defp command_for(:bash, code), do: {"bash", ["-c", code]}
end
