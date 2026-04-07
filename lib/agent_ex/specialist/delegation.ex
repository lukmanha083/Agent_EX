defmodule AgentEx.Specialist.Delegation do
  @moduledoc """
  Transparent sub-specialist spawning.

  A specialist can delegate work to another specialist without the
  orchestrator knowing. The sub-specialist runs under the DelegationSupervisor,
  and the parent monitors it to collect the result.

  This enables hierarchical agent teams:
  ```
  Orchestrator → Researcher → FactChecker (sub-delegate)
                             → Reporter back to Researcher
  ```
  """

  alias AgentEx.Specialist

  require Logger

  @default_timeout 120_000

  @doc """
  Delegate a task to a sub-specialist synchronously.

  Spawns the sub-specialist under DelegationSupervisor, monitors it,
  and waits for the result. Returns `{:ok, result_text, usage}` or
  `{:error, reason}`.
  """
  def delegate(%Specialist{} = specialist, task_input, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    task = %{
      id: "sub-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}",
      specialist: specialist.name,
      input: task_input
    }

    caller = self()

    case DynamicSupervisor.start_child(
           AgentEx.Specialist.DelegationSupervisor,
           {Task, fn -> run_and_report(specialist, task, caller, opts) end}
         ) do
      {:ok, pid} ->
        await_delegation(pid, specialist.name, timeout)

      {:error, reason} ->
        Logger.error("Failed to start delegation to #{specialist.name}: #{inspect(reason)}")
        {:error, {:delegation_start_failed, reason}}
    end
  end

  defp await_delegation(pid, name, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:delegation_result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        Logger.error("Delegation to #{name} crashed: #{inspect(reason)}")
        {:error, {:delegation_failed, reason}}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        DynamicSupervisor.terminate_child(AgentEx.Specialist.DelegationSupervisor, pid)
        Logger.warning("Delegation to #{name} timed out after #{timeout}ms")
        {:error, :delegation_timeout}
    end
  end

  @doc """
  Generate delegation tools for a specialist's tool set.

  For each name in `can_delegate_to`, creates a Tool that calls
  `delegate/3` synchronously when invoked.
  """
  def delegation_tools(can_delegate_to, specialists, opts \\ []) do
    Enum.flat_map(can_delegate_to, fn name ->
      case Map.get(specialists, name) do
        nil ->
          Logger.warning("Delegation: specialist '#{name}' not found, skipping")
          []

        specialist ->
          [build_delegation_tool(specialist, opts)]
      end
    end)
  end

  defp run_and_report(specialist, task, caller, opts) do
    result = Specialist.execute(specialist, task, opts)
    send(caller, {:delegation_result, self(), result})
  end

  defp build_delegation_tool(specialist, opts) do
    %AgentEx.Tool{
      name: "delegate_to_#{specialist.name}",
      description:
        "Delegate a sub-task to the #{specialist.name} specialist. #{specialist.description || ""}",
      kind: :write,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "task" => %{"type" => "string", "description" => "What the sub-specialist should do"}
        },
        "required" => ["task"]
      },
      function: fn %{"task" => task_input} ->
        case delegate(specialist, task_input, opts) do
          {:ok, result, _usage} -> {:ok, result}
          {:error, reason} -> {:error, inspect(reason)}
        end
      end
    }
  end
end
