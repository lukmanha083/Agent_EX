defmodule AgentEx.Memory.PersistentMemory.StoreTest do
  use ExUnit.Case, async: false

  alias AgentEx.Memory.PersistentMemory.Store

  @test_uid "test-user"
  @test_pid "test-project"
  @agent "test-agent"

  setup do
    for entry <- Store.all(@test_uid, @test_pid, @agent), do: Store.delete(@test_uid, @test_pid, @agent, entry.key)
    :ok
  end

  test "put and get an entry" do
    :ok = Store.put(@test_uid, @test_pid, @agent, "language", "elixir", "preference")
    assert {:ok, entry} = Store.get(@test_uid, @test_pid, @agent, "language")
    assert entry.value == "elixir"
    assert entry.type == "preference"
  end

  test "get returns :not_found for missing key" do
    assert :not_found = Store.get(@test_uid, @test_pid, @agent, "nonexistent_#{System.unique_integer()}")
  end

  test "get_by_type filters entries" do
    Store.put(@test_uid, @test_pid, @agent, "lang", "elixir", "preference")
    Store.put(@test_uid, @test_pid, @agent, "name", "Lukman", "fact")
    Store.put(@test_uid, @test_pid, @agent, "units", "metric", "preference")

    prefs = Store.get_by_type(@test_uid, @test_pid, @agent, "preference")
    assert length(prefs) == 2
    assert Enum.all?(prefs, &(&1.type == "preference"))
  end

  test "delete removes an entry" do
    Store.put(@test_uid, @test_pid, @agent, "temp", "value", "test")
    :ok = Store.delete(@test_uid, @test_pid, @agent, "temp")
    assert :not_found = Store.get(@test_uid, @test_pid, @agent, "temp")
  end

  test "all returns all entries for agent" do
    Store.put(@test_uid, @test_pid, @agent, "a", "1", "t")
    Store.put(@test_uid, @test_pid, @agent, "b", "2", "t")
    assert length(Store.all(@test_uid, @test_pid, @agent)) >= 2
  end

  test "to_context_messages formats entries" do
    Store.put(@test_uid, @test_pid, @agent, "lang", "elixir", "preference")
    messages = Store.to_context_messages({@test_uid, @test_pid, @agent})
    assert [%{role: "system", content: content}] = messages
    assert content =~ "lang: elixir"
  end

  test "survives process restart (DETS rehydration)" do
    Store.put(@test_uid, @test_pid, @agent, "persistent_key", "survives", "test")

    pid = Process.whereis(Store)
    Process.exit(pid, :kill)
    Process.sleep(100)

    assert {:ok, entry} = Store.get(@test_uid, @test_pid, @agent, "persistent_key")
    assert entry.value == "survives"
  end

  test "different agents are isolated" do
    agent_a = "iso-agent-a"
    agent_b = "iso-agent-b"

    Store.put(@test_uid, @test_pid, agent_a, "key", "value-a", "test")
    Store.put(@test_uid, @test_pid, agent_b, "key", "value-b", "test")

    assert {:ok, %{value: "value-a"}} = Store.get(@test_uid, @test_pid, agent_a, "key")
    assert {:ok, %{value: "value-b"}} = Store.get(@test_uid, @test_pid, agent_b, "key")

    # all/3 only returns that agent's entries
    assert Enum.all?(Store.all(@test_uid, @test_pid, agent_a), &(&1.value == "value-a"))
    assert Enum.all?(Store.all(@test_uid, @test_pid, agent_b), &(&1.value == "value-b"))

    Store.delete(@test_uid, @test_pid, agent_a, "key")
    Store.delete(@test_uid, @test_pid, agent_b, "key")
  end
end
