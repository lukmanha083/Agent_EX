defmodule AgentEx.InterventionTest do
  use ExUnit.Case

  alias AgentEx.{Intervention, Sensing, Tool, ToolAgent}
  alias AgentEx.Intervention.{LogHandler, PermissionHandler, WriteGateHandler}
  alias AgentEx.Message.{FunctionCall, FunctionResult}

  setup do
    read_tool =
      Tool.new(
        name: "get_weather",
        description: "Get weather",
        kind: :read,
        parameters: %{},
        function: fn %{"city" => city} -> {:ok, "#{city}: Sunny"} end
      )

    write_tool =
      Tool.new(
        name: "send_email",
        description: "Send email",
        kind: :write,
        parameters: %{},
        function: fn %{"to" => to} -> {:ok, "Sent to #{to}"} end
      )

    dangerous_tool =
      Tool.new(
        name: "delete_all",
        description: "Delete everything",
        kind: :write,
        parameters: %{},
        function: fn _ -> {:ok, "Deleted"} end
      )

    tools = [read_tool, write_tool, dangerous_tool]
    tools_map = Map.new(tools, fn t -> {t.name, t} end)
    {:ok, agent} = ToolAgent.start_link(tools: tools)
    context = %{iteration: 0, generated_messages: []}

    %{
      read_tool: read_tool,
      write_tool: write_tool,
      dangerous_tool: dangerous_tool,
      tools_map: tools_map,
      agent: agent,
      context: context
    }
  end

  # -- Tool :kind --

  describe "Tool kind" do
    test "defaults to :read" do
      tool = Tool.new(name: "t", description: "t", parameters: %{}, function: fn _ -> {:ok, 1} end)
      assert tool.kind == :read
      assert Tool.read?(tool)
      refute Tool.write?(tool)
    end

    test "can be set to :write", %{write_tool: write_tool} do
      assert write_tool.kind == :write
      assert Tool.write?(write_tool)
      refute Tool.read?(write_tool)
    end
  end

  # -- Intervention pipeline --

  describe "Intervention.run_pipeline/4" do
    test "empty pipeline approves everything", %{dangerous_tool: dt, context: ctx} do
      call = %FunctionCall{id: "c1", name: "delete_all", arguments: "{}"}
      assert :approve == Intervention.run_pipeline([], call, dt, ctx)
    end

    test "module handler works", %{write_tool: wt, context: ctx} do
      call = %FunctionCall{id: "c1", name: "send_email", arguments: "{}"}
      assert :reject == Intervention.run_pipeline([PermissionHandler], call, wt, ctx)
    end

    test "function handler works", %{read_tool: rt, context: ctx} do
      handler = fn _call, _tool, _ctx -> :reject end
      call = %FunctionCall{id: "c1", name: "get_weather", arguments: "{}"}
      assert :reject == Intervention.run_pipeline([handler], call, rt, ctx)
    end

    test "first deny wins (short-circuit)", %{read_tool: rt, context: ctx} do
      always_approve = fn _c, _t, _ctx -> :approve end
      always_reject = fn _c, _t, _ctx -> :reject end
      never_reached = fn _c, _t, _ctx -> raise "should not be called" end

      call = %FunctionCall{id: "c1", name: "test", arguments: "{}"}

      assert :reject ==
               Intervention.run_pipeline(
                 [always_approve, always_reject, never_reached],
                 call,
                 rt,
                 ctx
               )
    end

    test "all approve → approve", %{read_tool: rt, context: ctx} do
      h1 = fn _c, _t, _ctx -> :approve end
      h2 = fn _c, _t, _ctx -> :approve end
      call = %FunctionCall{id: "c1", name: "test", arguments: "{}"}
      assert :approve == Intervention.run_pipeline([h1, h2], call, rt, ctx)
    end
  end

  # -- PermissionHandler --

  describe "PermissionHandler" do
    test "approves read tools", %{read_tool: rt, context: ctx} do
      call = %FunctionCall{id: "c1", name: "get_weather", arguments: "{}"}
      assert :approve == PermissionHandler.on_call(call, rt, ctx)
    end

    test "rejects write tools", %{write_tool: wt, context: ctx} do
      call = %FunctionCall{id: "c1", name: "send_email", arguments: "{}"}
      assert :reject == PermissionHandler.on_call(call, wt, ctx)
    end
  end

  # -- WriteGateHandler --

  describe "WriteGateHandler" do
    test "approves read tools", %{read_tool: rt, context: ctx} do
      handler = WriteGateHandler.new(allowed_writes: [])
      call = %FunctionCall{id: "c1", name: "get_weather", arguments: "{}"}
      assert :approve == handler.(call, rt, ctx)
    end

    test "approves write tools in allowlist", %{write_tool: wt, context: ctx} do
      handler = WriteGateHandler.new(allowed_writes: ["send_email"])
      call = %FunctionCall{id: "c1", name: "send_email", arguments: "{}"}
      assert :approve == handler.(call, wt, ctx)
    end

    test "rejects write tools NOT in allowlist", %{dangerous_tool: dt, context: ctx} do
      handler = WriteGateHandler.new(allowed_writes: ["send_email"])
      call = %FunctionCall{id: "c1", name: "delete_all", arguments: "{}"}
      assert :reject == handler.(call, dt, ctx)
    end

    test "approves unknown tools (nil)", %{context: ctx} do
      handler = WriteGateHandler.new(allowed_writes: [])
      call = %FunctionCall{id: "c1", name: "unknown", arguments: "{}"}
      assert :approve == handler.(call, nil, ctx)
    end
  end

  # -- LogHandler --

  describe "LogHandler" do
    test "always approves", %{dangerous_tool: dt, context: ctx} do
      call = %FunctionCall{id: "c1", name: "delete_all", arguments: "{}"}
      assert :approve == LogHandler.on_call(call, dt, ctx)
    end
  end

  # -- Sensing + intervention integration --

  describe "Sensing with intervention" do
    test "no intervention — all calls execute", %{agent: agent} do
      calls = [
        %FunctionCall{id: "c1", name: "get_weather", arguments: ~s({"city": "Tokyo"})},
        %FunctionCall{id: "c2", name: "send_email", arguments: ~s({"to": "bob"})}
      ]

      {:ok, _msg, observations} = Sensing.sense(agent, calls)

      assert length(observations) == 2
      assert Enum.all?(observations, &(not &1.is_error))
    end

    test "PermissionHandler blocks write tools", %{agent: agent, tools_map: tm} do
      calls = [
        %FunctionCall{id: "c1", name: "get_weather", arguments: ~s({"city": "Tokyo"})},
        %FunctionCall{id: "c2", name: "send_email", arguments: ~s({"to": "bob"})},
        %FunctionCall{id: "c3", name: "delete_all", arguments: "{}"}
      ]

      {:ok, _msg, observations} =
        Sensing.sense(agent, calls, intervention: [PermissionHandler], tools_map: tm)

      assert length(observations) == 3
      assert %FunctionResult{call_id: "c1", is_error: false} = Enum.at(observations, 0)
      assert Enum.at(observations, 0).content =~ "Tokyo"

      assert %FunctionResult{call_id: "c2", is_error: true} = Enum.at(observations, 1)
      assert Enum.at(observations, 1).content =~ "permission denied"

      assert %FunctionResult{call_id: "c3", is_error: true} = Enum.at(observations, 2)
      assert Enum.at(observations, 2).content =~ "permission denied"
    end

    test "WriteGateHandler allows specific writes", %{agent: agent, tools_map: tm} do
      handler = WriteGateHandler.new(allowed_writes: ["send_email"])

      calls = [
        %FunctionCall{id: "c1", name: "get_weather", arguments: ~s({"city": "Tokyo"})},
        %FunctionCall{id: "c2", name: "send_email", arguments: ~s({"to": "bob"})},
        %FunctionCall{id: "c3", name: "delete_all", arguments: "{}"}
      ]

      {:ok, _msg, observations} =
        Sensing.sense(agent, calls, intervention: [handler], tools_map: tm)

      assert length(observations) == 3
      assert %FunctionResult{call_id: "c1", is_error: false} = Enum.at(observations, 0)
      assert %FunctionResult{call_id: "c2", is_error: false} = Enum.at(observations, 1)
      assert Enum.at(observations, 1).content =~ "Sent to bob"
      assert %FunctionResult{call_id: "c3", is_error: true} = Enum.at(observations, 2)
      assert Enum.at(observations, 2).content =~ "permission denied"
    end

    test "drop removes call from results entirely", %{agent: agent, tools_map: tm} do
      dropper = fn
        %FunctionCall{name: "delete_all"}, _tool, _ctx -> :drop
        _call, _tool, _ctx -> :approve
      end

      calls = [
        %FunctionCall{id: "c1", name: "get_weather", arguments: ~s({"city": "Tokyo"})},
        %FunctionCall{id: "c2", name: "delete_all", arguments: "{}"}
      ]

      {:ok, _msg, observations} =
        Sensing.sense(agent, calls, intervention: [dropper], tools_map: tm)

      assert length(observations) == 1
      assert %FunctionResult{call_id: "c1", is_error: false} = hd(observations)
    end

    test "modify changes the call before execution", %{agent: agent, tools_map: tm} do
      modifier = fn
        %FunctionCall{name: "get_weather"} = call, _tool, _ctx ->
          {:modify, %{call | arguments: ~s({"city": "London"})}}

        _call, _tool, _ctx ->
          :approve
      end

      calls = [
        %FunctionCall{id: "c1", name: "get_weather", arguments: ~s({"city": "Tokyo"})}
      ]

      {:ok, _msg, observations} =
        Sensing.sense(agent, calls, intervention: [modifier], tools_map: tm)

      assert [%FunctionResult{call_id: "c1", is_error: false}] = observations
      assert hd(observations).content =~ "London"
    end
  end
end
