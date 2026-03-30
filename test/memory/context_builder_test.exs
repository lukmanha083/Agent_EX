defmodule AgentEx.Memory.ContextBuilderTest do
  use ExUnit.Case, async: false

  alias AgentEx.Memory.{ContextBuilder, PersistentMemory, ProceduralMemory, WorkingMemory}

  @test_uid "test-user"
  @test_pid "test-project"
  @agent "ctx-agent"

  setup do
    session_id = "ctx-sess-#{System.unique_integer([:positive])}"
    {:ok, _} = WorkingMemory.Supervisor.start_session(@test_uid, @test_pid, @agent, session_id)

    on_exit(fn ->
      WorkingMemory.Supervisor.stop_session(@test_uid, @test_pid, @agent, session_id)
    end)

    %{session_id: session_id}
  end

  test "build returns conversation messages", %{session_id: sid} do
    WorkingMemory.Server.add_message(@test_uid, @test_pid, @agent, sid, "user", "hello")
    WorkingMemory.Server.add_message(@test_uid, @test_pid, @agent, sid, "assistant", "hi there")

    messages = ContextBuilder.build(@test_uid, @test_pid, @agent, sid)
    user_msgs = Enum.filter(messages, &(&1.role == "user"))
    assert user_msgs != []
  end

  test "build includes persistent memory in system message", %{session_id: sid} do
    PersistentMemory.Store.put(
      @test_uid,
      @test_pid,
      @agent,
      "test_pref",
      "dark mode",
      "preference"
    )

    on_exit(fn -> PersistentMemory.Store.delete(@test_uid, @test_pid, @agent, "test_pref") end)
    WorkingMemory.Server.add_message(@test_uid, @test_pid, @agent, sid, "user", "hello")

    messages = ContextBuilder.build(@test_uid, @test_pid, @agent, sid)
    system_msgs = Enum.filter(messages, &(&1.role == "system"))
    assert system_msgs != []
    assert hd(system_msgs).content =~ "test_pref"
  end

  test "build with empty session returns empty or system-only", %{session_id: sid} do
    messages = ContextBuilder.build(@test_uid, @test_pid, @agent, sid)
    assert is_list(messages)
  end

  test "build with semantic_query option", %{session_id: sid} do
    WorkingMemory.Server.add_message(
      @test_uid,
      @test_pid,
      @agent,
      sid,
      "user",
      "tell me about Elixir"
    )

    messages = ContextBuilder.build(@test_uid, @test_pid, @agent, sid, semantic_query: "Elixir")
    assert is_list(messages)
  end

  test "build includes procedural skills in system message", %{session_id: sid} do
    skill =
      ProceduralMemory.Skill.new(%{
        name: "test_skill",
        domain: "testing",
        description: "A test skill",
        strategy: "Run tests, check output, fix failures",
        confidence: 0.9
      })

    ProceduralMemory.Store.put(@test_uid, @test_pid, @agent, skill)
    on_exit(fn -> ProceduralMemory.Store.delete(@test_uid, @test_pid, @agent, "test_skill") end)

    WorkingMemory.Server.add_message(@test_uid, @test_pid, @agent, sid, "user", "hello")

    messages = ContextBuilder.build(@test_uid, @test_pid, @agent, sid)
    system_msgs = Enum.filter(messages, &(&1.role == "system"))
    system_content = Enum.map_join(system_msgs, "\n", & &1.content)
    assert system_content =~ "test_skill"
    assert system_content =~ "Learned Skills"
  end
end
