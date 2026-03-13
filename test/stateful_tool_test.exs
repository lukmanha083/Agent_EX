defmodule AgentEx.StatefulToolTest do
  use ExUnit.Case, async: true

  alias AgentEx.{StatefulTool, Tool}

  # In-memory store for testing (avoids needing PersistentMemory.Store GenServer)
  defmodule MockStore do
    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def get(agent_id, key) do
      case Agent.get(__MODULE__, &Map.get(&1, {agent_id, key})) do
        nil -> :not_found
        value -> {:ok, value}
      end
    end

    def put(agent_id, key, value) do
      Agent.update(__MODULE__, &Map.put(&1, {agent_id, key}, value))
    end
  end

  setup do
    {:ok, _} = MockStore.start_link()

    counter_tool =
      Tool.new(
        name: "increment",
        description: "Increment a counter",
        parameters: %{},
        function: fn %{"__state" => %{"count" => c}} ->
          {:ok, "count: #{c + 1}", %{"count" => c + 1}}
        end
      )

    %{counter_tool: counter_tool}
  end

  describe "wrap/2" do
    test "wraps a tool with initial state", %{counter_tool: tool} do
      wrapped =
        StatefulTool.wrap(tool,
          state_key: "counter",
          agent_id: "test",
          initial_state: %{"count" => 0},
          store: MockStore
        )

      assert %Tool{name: "increment"} = wrapped
      assert {:ok, "count: 1"} = Tool.execute(wrapped, %{})
    end

    test "state persists across calls", %{counter_tool: tool} do
      wrapped =
        StatefulTool.wrap(tool,
          state_key: "counter",
          agent_id: "test",
          initial_state: %{"count" => 0},
          store: MockStore
        )

      assert {:ok, "count: 1"} = Tool.execute(wrapped, %{})
      assert {:ok, "count: 2"} = Tool.execute(wrapped, %{})
      assert {:ok, "count: 3"} = Tool.execute(wrapped, %{})
    end

    test "no state change with 2-tuple return" do
      tool =
        Tool.new(
          name: "peek",
          description: "Peek at state",
          parameters: %{},
          function: fn %{"__state" => state} ->
            {:ok, "state: #{inspect(state)}"}
          end
        )

      wrapped =
        StatefulTool.wrap(tool,
          state_key: "peek",
          agent_id: "test",
          initial_state: %{"val" => 42},
          store: MockStore
        )

      assert {:ok, "state: %{\"val\" => 42}"} = Tool.execute(wrapped, %{})
      # State unchanged, same result
      assert {:ok, "state: %{\"val\" => 42}"} = Tool.execute(wrapped, %{})
    end

    test "error propagation" do
      tool =
        Tool.new(
          name: "fail",
          description: "Always fails",
          parameters: %{},
          function: fn %{"__state" => _} ->
            {:error, "something went wrong"}
          end
        )

      wrapped =
        StatefulTool.wrap(tool,
          state_key: "fail",
          agent_id: "test",
          initial_state: %{},
          store: MockStore
        )

      assert {:error, "something went wrong"} = Tool.execute(wrapped, %{})
    end

    test "preserves tool metadata", %{counter_tool: tool} do
      wrapped =
        StatefulTool.wrap(tool,
          state_key: "counter",
          agent_id: "test",
          store: MockStore
        )

      assert wrapped.name == "increment"
      assert wrapped.description == "Increment a counter"
      assert wrapped.kind == :read
    end

    test "different agent_ids have separate state", %{counter_tool: tool} do
      wrapped_a =
        StatefulTool.wrap(tool,
          state_key: "counter",
          agent_id: "agent_a",
          initial_state: %{"count" => 0},
          store: MockStore
        )

      wrapped_b =
        StatefulTool.wrap(tool,
          state_key: "counter",
          agent_id: "agent_b",
          initial_state: %{"count" => 0},
          store: MockStore
        )

      assert {:ok, "count: 1"} = Tool.execute(wrapped_a, %{})
      assert {:ok, "count: 2"} = Tool.execute(wrapped_a, %{})
      # agent_b starts from 0, independent of agent_a
      assert {:ok, "count: 1"} = Tool.execute(wrapped_b, %{})
    end

    test "merges args with state" do
      tool =
        Tool.new(
          name: "search",
          description: "Search with history",
          parameters: %{},
          function: fn %{"query" => q, "__state" => %{"history" => h}} ->
            {:ok, "searched: #{q}", %{"history" => [q | h]}}
          end
        )

      wrapped =
        StatefulTool.wrap(tool,
          state_key: "search",
          agent_id: "test",
          initial_state: %{"history" => []},
          store: MockStore
        )

      assert {:ok, "searched: elixir"} = Tool.execute(wrapped, %{"query" => "elixir"})
      assert {:ok, "searched: otp"} = Tool.execute(wrapped, %{"query" => "otp"})
    end
  end
end
