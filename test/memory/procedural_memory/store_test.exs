defmodule AgentEx.Memory.ProceduralMemory.StoreTest do
  use ExUnit.Case, async: false

  alias AgentEx.Memory.ProceduralMemory.{Skill, Store}

  @test_uid "test-user"
  @test_pid "test-project"
  @agent "test-agent"

  @test_agents [@agent, "agent1", "agent2", "agent_a", "agent_b"]

  setup do
    for agent <- @test_agents,
        skill <- Store.all(@test_uid, @test_pid, agent),
        do: Store.delete(@test_uid, @test_pid, agent, skill.name)

    :ok
  end

  defp make_skill(name, opts \\ []) do
    Skill.new(%{
      name: name,
      domain: Keyword.get(opts, :domain, "general"),
      description: "A test skill: #{name}",
      strategy: Keyword.get(opts, :strategy, "Do the thing step by step"),
      confidence: Keyword.get(opts, :confidence, 0.5),
      tool_patterns: Keyword.get(opts, :tool_patterns, []),
      error_patterns: Keyword.get(opts, :error_patterns, [])
    })
  end

  describe "put and get" do
    test "stores and retrieves a skill" do
      skill = make_skill("web_research")
      Store.put(@test_uid, @test_pid, @agent, skill)

      assert {:ok, retrieved} = Store.get(@test_uid, @test_pid, @agent, "web_research")
      assert retrieved.name == "web_research"
      assert retrieved.domain == "general"
      assert retrieved.strategy == "Do the thing step by step"
    end

    test "returns :not_found for missing skill" do
      assert :not_found = Store.get(@test_uid, @test_pid, @agent, "nonexistent")
    end

    test "upserts on same name" do
      skill1 = make_skill("research", strategy: "approach A")
      Store.put(@test_uid, @test_pid, @agent, skill1)

      skill2 = make_skill("research", strategy: "approach B")
      Store.put(@test_uid, @test_pid, @agent, skill2)

      assert {:ok, retrieved} = Store.get(@test_uid, @test_pid, @agent, "research")
      assert retrieved.strategy == "approach B"
    end
  end

  describe "all" do
    test "returns all skills for agent" do
      Store.put(@test_uid, @test_pid, @agent, make_skill("skill_a"))
      Store.put(@test_uid, @test_pid, @agent, make_skill("skill_b"))

      skills = Store.all(@test_uid, @test_pid, @agent)
      assert length(skills) == 2
      names = Enum.map(skills, & &1.name) |> Enum.sort()
      assert names == ["skill_a", "skill_b"]
    end
  end

  describe "get_by_domain" do
    test "filters skills by domain" do
      Store.put(@test_uid, @test_pid, @agent, make_skill("s1", domain: "research"))
      Store.put(@test_uid, @test_pid, @agent, make_skill("s2", domain: "code"))
      Store.put(@test_uid, @test_pid, @agent, make_skill("s3", domain: "research"))

      research = Store.get_by_domain(@test_uid, @test_pid, @agent, "research")
      assert length(research) == 2

      code = Store.get_by_domain(@test_uid, @test_pid, @agent, "code")
      assert length(code) == 1
    end
  end

  describe "get_top_skills" do
    test "returns skills sorted by confidence descending" do
      Store.put(@test_uid, @test_pid, @agent, make_skill("low", confidence: 0.3))
      Store.put(@test_uid, @test_pid, @agent, make_skill("high", confidence: 0.9))
      Store.put(@test_uid, @test_pid, @agent, make_skill("mid", confidence: 0.6))

      top = Store.get_top_skills(@test_uid, @test_pid, @agent, 2)
      assert length(top) == 2
      assert hd(top).name == "high"
      assert List.last(top).name == "mid"
    end
  end

  describe "delete" do
    test "removes a skill" do
      Store.put(@test_uid, @test_pid, @agent, make_skill("doomed"))
      assert {:ok, _} = Store.get(@test_uid, @test_pid, @agent, "doomed")

      Store.delete(@test_uid, @test_pid, @agent, "doomed")
      assert :not_found = Store.get(@test_uid, @test_pid, @agent, "doomed")
    end
  end

  describe "delete_all" do
    test "removes all skills for agent" do
      Store.put(@test_uid, @test_pid, @agent, make_skill("a"))
      Store.put(@test_uid, @test_pid, @agent, make_skill("b"))

      assert {:ok, 2} = Store.delete_all(@test_uid, @test_pid, @agent)
      assert Store.all(@test_uid, @test_pid, @agent) == []
    end
  end

  describe "delete_by_project" do
    test "removes all skills for a project" do
      Store.put(@test_uid, @test_pid, "agent1", make_skill("s1"))
      Store.put(@test_uid, @test_pid, "agent2", make_skill("s2"))

      assert {:ok, 2} = Store.delete_by_project(@test_uid, @test_pid)
      assert Store.all(@test_uid, @test_pid, "agent1") == []
      assert Store.all(@test_uid, @test_pid, "agent2") == []
    end
  end

  describe "agent isolation" do
    test "different agents have separate skills" do
      Store.put(@test_uid, @test_pid, "agent_a", make_skill("shared_name"))
      Store.put(@test_uid, @test_pid, "agent_b", make_skill("shared_name"))

      assert length(Store.all(@test_uid, @test_pid, "agent_a")) == 1
      assert length(Store.all(@test_uid, @test_pid, "agent_b")) == 1

      Store.delete_all(@test_uid, @test_pid, "agent_a")
      assert Store.all(@test_uid, @test_pid, "agent_a") == []
      assert length(Store.all(@test_uid, @test_pid, "agent_b")) == 1

      # cleanup
      Store.delete_all(@test_uid, @test_pid, "agent_b")
    end
  end

  describe "to_context_messages" do
    test "returns empty list when no skills" do
      assert Store.to_context_messages({@test_uid, @test_pid, @agent}) == []
    end

    test "formats skills as system message" do
      Store.put(
        @test_uid,
        @test_pid,
        @agent,
        make_skill("data_pipeline",
          domain: "data",
          confidence: 0.85,
          tool_patterns: ["query_db", "transform", "export"],
          error_patterns: ["retry on timeout"]
        )
      )

      [%{role: "system", content: content}] =
        Store.to_context_messages({@test_uid, @test_pid, @agent})

      assert content =~ "Learned Skills & Strategies"
      assert content =~ "data_pipeline"
      assert content =~ "85% confidence"
      assert content =~ "query_db -> transform -> export"
      assert content =~ "retry on timeout"
    end
  end

  describe "token_estimate" do
    test "estimates tokens for skills" do
      Store.put(@test_uid, @test_pid, @agent, make_skill("s1"))
      estimate = Store.token_estimate({@test_uid, @test_pid, @agent})
      assert estimate > 0
    end

    test "returns 0 for no skills" do
      assert Store.token_estimate({@test_uid, @test_pid, @agent}) == 0
    end
  end

  describe "DETS persistence" do
    test "skills survive process restart" do
      Store.put(@test_uid, @test_pid, @agent, make_skill("persistent_skill", confidence: 0.99))
      assert {:ok, _} = Store.get(@test_uid, @test_pid, @agent, "persistent_skill")

      # Kill and restart the GenServer
      pid = Process.whereis(Store)
      Process.exit(pid, :kill)
      Process.sleep(100)

      # Wait for supervisor restart
      assert {:ok, retrieved} = Store.get(@test_uid, @test_pid, @agent, "persistent_skill")
      assert retrieved.name == "persistent_skill"
      assert retrieved.confidence == 0.99
    end
  end
end
