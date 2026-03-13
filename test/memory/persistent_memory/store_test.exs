defmodule AgentEx.Memory.PersistentMemory.StoreTest do
  use ExUnit.Case, async: false

  alias AgentEx.Memory.PersistentMemory.Store

  @agent "test-agent"

  setup do
    for entry <- Store.all(@agent), do: Store.delete(@agent, entry.key)
    :ok
  end

  test "put and get an entry" do
    :ok = Store.put(@agent, "language", "elixir", "preference")
    assert {:ok, entry} = Store.get(@agent, "language")
    assert entry.value == "elixir"
    assert entry.type == "preference"
  end

  test "get returns :not_found for missing key" do
    assert :not_found = Store.get(@agent, "nonexistent_#{System.unique_integer()}")
  end

  test "get_by_type filters entries" do
    Store.put(@agent, "lang", "elixir", "preference")
    Store.put(@agent, "name", "Lukman", "fact")
    Store.put(@agent, "units", "metric", "preference")

    prefs = Store.get_by_type(@agent, "preference")
    assert length(prefs) == 2
    assert Enum.all?(prefs, &(&1.type == "preference"))
  end

  test "delete removes an entry" do
    Store.put(@agent, "temp", "value", "test")
    :ok = Store.delete(@agent, "temp")
    assert :not_found = Store.get(@agent, "temp")
  end

  test "all returns all entries for agent" do
    Store.put(@agent, "a", "1", "t")
    Store.put(@agent, "b", "2", "t")
    assert length(Store.all(@agent)) >= 2
  end

  test "to_context_messages formats entries" do
    Store.put(@agent, "lang", "elixir", "preference")
    messages = Store.to_context_messages(@agent)
    assert [%{role: "system", content: content}] = messages
    assert content =~ "lang: elixir"
  end

  test "survives process restart (DETS rehydration)" do
    Store.put(@agent, "persistent_key", "survives", "test")

    pid = Process.whereis(Store)
    Process.exit(pid, :kill)
    Process.sleep(100)

    assert {:ok, entry} = Store.get(@agent, "persistent_key")
    assert entry.value == "survives"
  end

  test "different agents are isolated" do
    agent_a = "iso-agent-a"
    agent_b = "iso-agent-b"

    Store.put(agent_a, "key", "value-a", "test")
    Store.put(agent_b, "key", "value-b", "test")

    assert {:ok, %{value: "value-a"}} = Store.get(agent_a, "key")
    assert {:ok, %{value: "value-b"}} = Store.get(agent_b, "key")

    # all/1 only returns that agent's entries
    assert Enum.all?(Store.all(agent_a), &(&1.value == "value-a"))
    assert Enum.all?(Store.all(agent_b), &(&1.value == "value-b"))

    Store.delete(agent_a, "key")
    Store.delete(agent_b, "key")
  end
end
