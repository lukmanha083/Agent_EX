defmodule AgentEx.StatefulTool do
  @moduledoc """
  Wrap a tool so its function receives persisted state and can update it.

  Maps to AutoGen's `BaseToolWithState` with `save_state()`/`load_state()`.
  Uses `AgentEx.Memory.PersistentMemory.Store` (Tier 2) for persistence.

  ## Stateful function signature

  The wrapped function receives a `"__state"` key merged into its arguments:

      fn %{"query" => q, "__state" => %{"history" => h}} ->
        new_history = [q | h]
        {:ok, "searched: \#{q}", %{"history" => new_history}}
      end

  Return values:
  - `{:ok, result}` — no state change
  - `{:ok, result, new_state}` — state updated and persisted

  ## Example

      counter_tool = Tool.new(
        name: "increment",
        description: "Increment a counter",
        parameters: %{},
        function: fn %{"__state" => %{"count" => c}} ->
          {:ok, "count: \#{c + 1}", %{"count" => c + 1}}
        end
      )

      wrapped = StatefulTool.wrap(counter_tool,
        state_key: "counter",
        agent_id: "bot",
        initial_state: %{"count" => 0}
      )
  """

  alias AgentEx.Memory.PersistentMemory
  alias AgentEx.Tool

  @state_prefix "tool_state:"

  @doc """
  Wrap a tool with persistent state.

  ## Options
  - `:state_key` — unique key for this tool's state (required)
  - `:agent_id` — agent scope for persistence (required)
  - `:initial_state` — default state when none exists (default: `%{}`)
  - `:store` — module implementing get/put (default: PersistentMemory.Store)
  """
  @spec wrap(Tool.t(), keyword()) :: Tool.t()
  def wrap(%Tool{} = tool, opts) do
    state_key = Keyword.fetch!(opts, :state_key)
    agent_id = Keyword.fetch!(opts, :agent_id)
    user_id = Keyword.get(opts, :user_id)
    project_id = Keyword.get(opts, :project_id)
    initial_state = Keyword.get(opts, :initial_state, %{})
    store = Keyword.get(opts, :store)

    original_fn = tool.function
    storage_key = @state_prefix <> state_key

    stateful_fn = fn args ->
      current_state = load_state(store, user_id, project_id, agent_id, storage_key, initial_state)
      args_with_state = Map.put(args, "__state", current_state)

      case original_fn.(args_with_state) do
        {:ok, result, new_state} ->
          save_state(store, user_id, project_id, agent_id, storage_key, new_state)
          {:ok, result}

        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    end

    %Tool{tool | function: stateful_fn}
  end

  defp load_state(nil, user_id, project_id, agent_id, key, initial) do
    case PersistentMemory.Store.get(user_id, project_id, agent_id, key) do
      {:ok, entry} -> entry.value
      :not_found -> initial
    end
  end

  defp load_state(store, _user_id, _project_id, agent_id, key, initial) do
    case store.get(agent_id, key) do
      {:ok, value} -> value
      :not_found -> initial
    end
  end

  defp save_state(nil, user_id, project_id, agent_id, key, state) do
    PersistentMemory.Store.put(user_id, project_id, agent_id, key, state, "tool_state")
  end

  defp save_state(store, _user_id, _project_id, agent_id, key, state) do
    store.put(agent_id, key, state)
  end
end
