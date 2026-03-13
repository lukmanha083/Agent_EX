defmodule AgentEx.Memory.ContextBuilderTest do
  use ExUnit.Case, async: false

  alias AgentEx.Memory.{ContextBuilder, PersistentMemory, WorkingMemory}

  @agent "ctx-agent"

  setup do
    session_id = "ctx-sess-#{System.unique_integer([:positive])}"
    {:ok, _} = WorkingMemory.Supervisor.start_session(@agent, session_id)
    on_exit(fn -> WorkingMemory.Supervisor.stop_session(@agent, session_id) end)
    %{session_id: session_id}
  end

  test "build returns conversation messages", %{session_id: sid} do
    WorkingMemory.Server.add_message(@agent, sid, "user", "hello")
    WorkingMemory.Server.add_message(@agent, sid, "assistant", "hi there")

    messages = ContextBuilder.build(@agent, sid)
    user_msgs = Enum.filter(messages, &(&1.role == "user"))
    assert user_msgs != []
  end

  test "build includes persistent memory in system message", %{session_id: sid} do
    PersistentMemory.Store.put(@agent, "test_pref", "dark mode", "preference")
    WorkingMemory.Server.add_message(@agent, sid, "user", "hello")

    messages = ContextBuilder.build(@agent, sid)
    system_msgs = Enum.filter(messages, &(&1.role == "system"))
    assert system_msgs != []
    assert hd(system_msgs).content =~ "test_pref"

    PersistentMemory.Store.delete(@agent, "test_pref")
  end

  test "build with empty session returns empty or system-only", %{session_id: sid} do
    messages = ContextBuilder.build(@agent, sid)
    assert is_list(messages)
  end

  test "build with semantic_query option", %{session_id: sid} do
    WorkingMemory.Server.add_message(@agent, sid, "user", "tell me about Elixir")
    messages = ContextBuilder.build(@agent, sid, semantic_query: "Elixir")
    assert is_list(messages)
  end
end
