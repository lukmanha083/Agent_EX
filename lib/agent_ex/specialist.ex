defmodule AgentEx.Specialist do
  @moduledoc """
  A specialist agent definition for the orchestration engine.

  Each specialist has its own tool set, model client, and execution config.
  The Orchestrator dispatches tasks to specialists via the Pool, and each
  task runs in an isolated Worker process using the existing ToolCallerLoop.
  """

  defstruct [
    :name,
    :system_message,
    :model_client,
    :description,
    :role,
    tools: [],
    plugins: [],
    intervention: [],
    max_iterations: 10,
    can_delegate_to: [],
    compress_result: true
  ]

  @type t :: %__MODULE__{}

  alias AgentEx.{Message, ToolAgent, ToolCallerLoop}
  alias AgentEx.Specialist.Delegation

  @doc """
  Execute a task using this specialist's tools and model.

  Starts an ephemeral ToolAgent, runs the ToolCallerLoop, extracts the
  final text response and token usage, then cleans up.

  Returns `{:ok, result_text, usage}` or `{:error, reason}`.
  """
  def execute(%__MODULE__{} = specialist, task, opts \\ []) do
    model_fn = Keyword.get(opts, :model_fn)

    messages = [
      Message.system(
        specialist.system_message ||
          (specialist.name && "You are #{specialist.name}.") ||
          "You are a specialist."
      ),
      Message.user(task.input)
    ]

    specialists_map = Keyword.get(opts, :specialists, %{})

    tools =
      if specialist.can_delegate_to != [] do
        delegation_tools =
          Delegation.delegation_tools(specialist.can_delegate_to, specialists_map, opts)

        specialist.tools ++ delegation_tools
      else
        specialist.tools
      end

    case start_tool_agent(tools) do
      {:ok, tool_agent} ->
        result =
          try do
            run_loop(tool_agent, specialist, messages, tools, model_fn)
          after
            GenServer.stop(tool_agent, :normal)
          end

        result

      {:error, reason} ->
        {:error, {:tool_agent_start_failed, reason}}
    end
  end

  defp start_tool_agent(tools) do
    ToolAgent.start_link(tools: tools)
  end

  defp run_loop(tool_agent, specialist, messages, tools, model_fn) do
    loop_opts = [
      max_iterations: specialist.max_iterations,
      intervention: specialist.intervention
    ]

    loop_opts = if model_fn, do: Keyword.put(loop_opts, :model_fn, model_fn), else: loop_opts

    case ToolCallerLoop.run(tool_agent, specialist.model_client, messages, tools, loop_opts) do
      {:ok, generated} ->
        result_text = extract_final_text(generated)
        usage = extract_usage(generated)
        {:ok, result_text, usage}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_final_text(generated) do
    generated
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %Message{role: :assistant, content: content} when is_binary(content) and content != "" ->
        content

      _ ->
        nil
    end)
  end

  defp extract_usage(generated) do
    generated
    |> Enum.reduce(0, fn
      %Message{usage: %{input_tokens: i, output_tokens: o}}, acc -> acc + i + o
      _, acc -> acc
    end)
  end
end
