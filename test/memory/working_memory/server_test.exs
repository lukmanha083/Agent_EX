defmodule AgentEx.Memory.WorkingMemory.ServerTest do
  use ExUnit.Case, async: false

  alias AgentEx.Memory.WorkingMemory.{Server, Supervisor}

  @test_uid "test-user"
  @test_pid "test-project"

  setup do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    session_id = "sess-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Supervisor.start_session(@test_uid, @test_pid, agent_id, session_id, max_messages: 5)
    on_exit(fn -> Supervisor.stop_session(@test_uid, @test_pid, agent_id, session_id) end)
    %{agent_id: agent_id, session_id: session_id}
  end

  test "add and retrieve messages", %{agent_id: aid, session_id: sid} do
    :ok = Server.add_message(@test_uid, @test_pid, aid, sid, "user", "hello")
    :ok = Server.add_message(@test_uid, @test_pid, aid, sid, "assistant", "hi there")

    messages = Server.get_messages(@test_uid, @test_pid, aid, sid)
    assert length(messages) == 2
    assert hd(messages).role == "user"
    assert hd(messages).content == "hello"
  end

  test "get_recent returns last N messages", %{agent_id: aid, session_id: sid} do
    for i <- 1..4, do: Server.add_message(@test_uid, @test_pid, aid, sid, "user", "msg #{i}")

    recent = Server.get_recent(@test_uid, @test_pid, aid, sid, 2)
    assert length(recent) == 2
    assert hd(recent).content == "msg 3"
    assert List.last(recent).content == "msg 4"
  end

  test "enforces max_messages limit", %{agent_id: aid, session_id: sid} do
    for i <- 1..8, do: Server.add_message(@test_uid, @test_pid, aid, sid, "user", "msg #{i}")

    messages = Server.get_messages(@test_uid, @test_pid, aid, sid)
    assert length(messages) == 5
    assert hd(messages).content == "msg 4"
  end

  test "clear removes all messages", %{agent_id: aid, session_id: sid} do
    Server.add_message(@test_uid, @test_pid, aid, sid, "user", "hello")
    :ok = Server.clear(@test_uid, @test_pid, aid, sid)
    assert Server.get_messages(@test_uid, @test_pid, aid, sid) == []
  end

  test "to_context_messages returns role/content maps", %{agent_id: aid, session_id: sid} do
    Server.add_message(@test_uid, @test_pid, aid, sid, "user", "hello")
    Server.add_message(@test_uid, @test_pid, aid, sid, "assistant", "hi")

    messages = Server.to_context_messages({@test_uid, @test_pid, aid}, sid)
    assert [%{role: "user", content: "hello"}, %{role: "assistant", content: "hi"}] = messages
  end

  test "token_estimate returns non-negative integer", %{agent_id: aid, session_id: sid} do
    Server.add_message(@test_uid, @test_pid, aid, sid, "user", String.duplicate("a", 100))
    assert Server.token_estimate({@test_uid, @test_pid, aid}, sid) == 25
  end

  test "stop_session terminates the process" do
    aid = "ephemeral-agent-#{System.unique_integer([:positive])}"
    sid = "ephemeral-sess-#{System.unique_integer([:positive])}"
    {:ok, _} = Supervisor.start_session(@test_uid, @test_pid, aid, sid)
    assert Server.whereis(@test_uid, @test_pid, aid, sid) != nil

    :ok = Supervisor.stop_session(@test_uid, @test_pid, aid, sid)
    Process.sleep(50)
    assert Server.whereis(@test_uid, @test_pid, aid, sid) == nil
  end

  test "different agents in same session are isolated" do
    sid = "shared-sess-#{System.unique_integer([:positive])}"
    agent_a = "agent-a-#{System.unique_integer([:positive])}"
    agent_b = "agent-b-#{System.unique_integer([:positive])}"

    {:ok, _} = Supervisor.start_session(@test_uid, @test_pid, agent_a, sid)
    {:ok, _} = Supervisor.start_session(@test_uid, @test_pid, agent_b, sid)

    Server.add_message(@test_uid, @test_pid, agent_a, sid, "user", "message for agent A")
    Server.add_message(@test_uid, @test_pid, agent_b, sid, "user", "message for agent B")

    assert [%{content: "message for agent A"}] = Server.get_messages(@test_uid, @test_pid, agent_a, sid)
    assert [%{content: "message for agent B"}] = Server.get_messages(@test_uid, @test_pid, agent_b, sid)

    Supervisor.stop_session(@test_uid, @test_pid, agent_a, sid)
    Supervisor.stop_session(@test_uid, @test_pid, agent_b, sid)
  end
end
