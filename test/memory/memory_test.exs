defmodule AgentEx.MemoryTest do
  use ExUnit.Case, async: false

  alias AgentEx.Memory

  test "session lifecycle via facade" do
    aid = "facade-agent-#{System.unique_integer([:positive])}"
    sid = "facade-sess-#{System.unique_integer([:positive])}"

    {:ok, _pid} = Memory.start_session(aid, sid)
    :ok = Memory.add_message(aid, sid, "user", "hello")
    :ok = Memory.add_message(aid, sid, "assistant", "hi")

    messages = Memory.get_messages(aid, sid)
    assert length(messages) == 2

    recent = Memory.get_recent_messages(aid, sid, 1)
    assert length(recent) == 1
    assert hd(recent).role == "assistant"

    :ok = Memory.stop_session(aid, sid)
  end

  test "persistent memory via facade" do
    aid = "pm-agent-#{System.unique_integer([:positive])}"

    :ok = Memory.remember(aid, "test_facade_key", "test_val", "test")
    assert {:ok, entry} = Memory.recall(aid, "test_facade_key")
    assert entry.value == "test_val"

    entries = Memory.recall_by_type(aid, "test")
    assert Enum.any?(entries, &(&1.key == "test_facade_key"))

    :ok = Memory.forget(aid, "test_facade_key")
    assert :not_found = Memory.recall(aid, "test_facade_key")
  end

  test "build_context doesn't crash" do
    aid = "ctx-agent-#{System.unique_integer([:positive])}"
    sid = "ctx-sess-#{System.unique_integer([:positive])}"
    {:ok, _} = Memory.start_session(aid, sid)
    Memory.add_message(aid, sid, "user", "test")

    messages = Memory.build_context(aid, sid)
    assert is_list(messages)

    Memory.stop_session(aid, sid)
  end

  test "multi-agent memory isolation" do
    sid = "shared-#{System.unique_integer([:positive])}"
    analyst = "analyst-#{System.unique_integer([:positive])}"
    writer = "writer-#{System.unique_integer([:positive])}"

    # Start sessions
    {:ok, _} = Memory.start_session(analyst, sid)
    {:ok, _} = Memory.start_session(writer, sid)

    # Each agent stores different messages
    Memory.add_message(analyst, sid, "user", "Analyze AAPL")
    Memory.add_message(writer, sid, "user", "Write a report")

    # Each agent remembers different things
    Memory.remember(analyst, "expertise", "data analysis", "fact")
    Memory.remember(writer, "style", "concise", "preference")

    # Verify isolation: working memory
    analyst_msgs = Memory.get_messages(analyst, sid)
    writer_msgs = Memory.get_messages(writer, sid)
    assert length(analyst_msgs) == 1
    assert hd(analyst_msgs).content == "Analyze AAPL"
    assert length(writer_msgs) == 1
    assert hd(writer_msgs).content == "Write a report"

    # Verify isolation: persistent memory
    assert {:ok, %{value: "data analysis"}} = Memory.recall(analyst, "expertise")
    assert :not_found = Memory.recall(writer, "expertise")
    assert {:ok, %{value: "concise"}} = Memory.recall(writer, "style")
    assert :not_found = Memory.recall(analyst, "style")

    # Context builds are agent-scoped
    analyst_ctx = Memory.build_context(analyst, sid)
    writer_ctx = Memory.build_context(writer, sid)
    assert analyst_ctx != writer_ctx

    # Cleanup
    Memory.forget(analyst, "expertise")
    Memory.forget(writer, "style")
    Memory.stop_session(analyst, sid)
    Memory.stop_session(writer, sid)
  end
end
