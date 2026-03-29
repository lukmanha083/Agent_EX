defmodule AgentEx.MemoryTest do
  use ExUnit.Case, async: false

  alias AgentEx.Memory

  @test_uid "test-user"
  @test_pid "test-project"

  test "session lifecycle via facade" do
    aid = "facade-agent-#{System.unique_integer([:positive])}"
    sid = "facade-sess-#{System.unique_integer([:positive])}"

    {:ok, _pid} = Memory.start_session(@test_uid, @test_pid, aid, sid)
    :ok = Memory.add_message(@test_uid, @test_pid, aid, sid, "user", "hello")
    :ok = Memory.add_message(@test_uid, @test_pid, aid, sid, "assistant", "hi")

    messages = Memory.get_messages(@test_uid, @test_pid, aid, sid)
    assert length(messages) == 2

    recent = Memory.get_recent_messages(@test_uid, @test_pid, aid, sid, 1)
    assert length(recent) == 1
    assert hd(recent).role == "assistant"

    :ok = Memory.stop_session(@test_uid, @test_pid, aid, sid)
  end

  test "persistent memory via facade" do
    aid = "pm-agent-#{System.unique_integer([:positive])}"

    :ok = Memory.remember(@test_uid, @test_pid, aid, "test_facade_key", "test_val", "test")
    assert {:ok, entry} = Memory.recall(@test_uid, @test_pid, aid, "test_facade_key")
    assert entry.value == "test_val"

    entries = Memory.recall_by_type(@test_uid, @test_pid, aid, "test")
    assert Enum.any?(entries, &(&1.key == "test_facade_key"))

    :ok = Memory.forget(@test_uid, @test_pid, aid, "test_facade_key")
    assert :not_found = Memory.recall(@test_uid, @test_pid, aid, "test_facade_key")
  end

  test "build_context doesn't crash" do
    aid = "ctx-agent-#{System.unique_integer([:positive])}"
    sid = "ctx-sess-#{System.unique_integer([:positive])}"
    {:ok, _} = Memory.start_session(@test_uid, @test_pid, aid, sid)
    Memory.add_message(@test_uid, @test_pid, aid, sid, "user", "test")

    messages = Memory.build_context(@test_uid, @test_pid, aid, sid)
    assert is_list(messages)

    Memory.stop_session(@test_uid, @test_pid, aid, sid)
  end

  test "multi-agent memory isolation" do
    sid = "shared-#{System.unique_integer([:positive])}"
    analyst = "analyst-#{System.unique_integer([:positive])}"
    writer = "writer-#{System.unique_integer([:positive])}"

    # Start sessions
    {:ok, _} = Memory.start_session(@test_uid, @test_pid, analyst, sid)
    {:ok, _} = Memory.start_session(@test_uid, @test_pid, writer, sid)

    # Each agent stores different messages
    Memory.add_message(@test_uid, @test_pid, analyst, sid, "user", "Analyze AAPL")
    Memory.add_message(@test_uid, @test_pid, writer, sid, "user", "Write a report")

    # Each agent remembers different things
    Memory.remember(@test_uid, @test_pid, analyst, "expertise", "data analysis", "fact")
    Memory.remember(@test_uid, @test_pid, writer, "style", "concise", "preference")

    # Verify isolation: working memory
    analyst_msgs = Memory.get_messages(@test_uid, @test_pid, analyst, sid)
    writer_msgs = Memory.get_messages(@test_uid, @test_pid, writer, sid)
    assert length(analyst_msgs) == 1
    assert hd(analyst_msgs).content == "Analyze AAPL"
    assert length(writer_msgs) == 1
    assert hd(writer_msgs).content == "Write a report"

    # Verify isolation: persistent memory
    assert {:ok, %{value: "data analysis"}} = Memory.recall(@test_uid, @test_pid, analyst, "expertise")
    assert :not_found = Memory.recall(@test_uid, @test_pid, writer, "expertise")
    assert {:ok, %{value: "concise"}} = Memory.recall(@test_uid, @test_pid, writer, "style")
    assert :not_found = Memory.recall(@test_uid, @test_pid, analyst, "style")

    # Context builds are agent-scoped
    analyst_ctx = Memory.build_context(@test_uid, @test_pid, analyst, sid)
    writer_ctx = Memory.build_context(@test_uid, @test_pid, writer, sid)
    assert analyst_ctx != writer_ctx

    # Cleanup
    Memory.forget(@test_uid, @test_pid, analyst, "expertise")
    Memory.forget(@test_uid, @test_pid, writer, "style")
    Memory.stop_session(@test_uid, @test_pid, analyst, sid)
    Memory.stop_session(@test_uid, @test_pid, writer, sid)
  end
end
