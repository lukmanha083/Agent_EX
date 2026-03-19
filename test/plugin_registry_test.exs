defmodule AgentEx.PluginRegistryTest do
  use ExUnit.Case, async: true

  alias AgentEx.{PluginRegistry, PluginRegistry.PluginInfo, Tool, Workbench}

  # -- Test plugin modules --

  defmodule SimplePlugin do
    @behaviour AgentEx.ToolPlugin

    @impl true
    def manifest do
      %{
        name: "simple",
        version: "1.0.0",
        description: "A simple test plugin",
        config_schema: [
          {:greeting, :string, "Greeting text"}
        ]
      }
    end

    @impl true
    def init(config) do
      greeting = Map.fetch!(config, "greeting")

      tool =
        Tool.new(
          name: "say_hello",
          description: "Say hello",
          parameters: %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"}
            },
            "required" => ["name"]
          },
          function: fn %{"name" => name} -> {:ok, "#{greeting}, #{name}!"} end
        )

      {:ok, [tool]}
    end
  end

  defmodule OptionalConfigPlugin do
    @behaviour AgentEx.ToolPlugin

    @impl true
    def manifest do
      %{
        name: "optional",
        version: "1.0.0",
        description: "Plugin with optional config",
        config_schema: [
          {:mode, :string, "Operating mode", optional: true}
        ]
      }
    end

    @impl true
    def init(_config) do
      tool =
        Tool.new(
          name: "noop",
          description: "Does nothing",
          parameters: %{},
          function: fn _ -> {:ok, "ok"} end
        )

      {:ok, [tool]}
    end
  end

  defmodule FailingPlugin do
    @behaviour AgentEx.ToolPlugin

    @impl true
    def manifest do
      %{
        name: "failing",
        version: "1.0.0",
        description: "Always fails init",
        config_schema: []
      }
    end

    @impl true
    def init(_config) do
      {:error, :init_boom}
    end
  end

  # -- Setup --

  setup do
    {:ok, wb} = Workbench.start_link()
    {:ok, reg} = PluginRegistry.start_link(workbench: wb)
    %{wb: wb, reg: reg}
  end

  # -- Tests --

  describe "attach/3" do
    test "attaches a plugin and registers prefixed tools", %{reg: reg, wb: wb} do
      assert :ok = PluginRegistry.attach(reg, SimplePlugin, %{"greeting" => "Hello"})

      tools = Workbench.list_tools(wb)
      assert length(tools) == 1
      assert hd(tools).name == "simple.say_hello"
    end

    test "plugin tools are callable", %{reg: reg, wb: wb} do
      :ok = PluginRegistry.attach(reg, SimplePlugin, %{"greeting" => "Hi"})

      result = Workbench.call_tool(wb, "simple.say_hello", %{"name" => "World"})
      assert result.content == "Hi, World!"
      assert result.is_error == false
    end

    test "rejects duplicate attachment", %{reg: reg} do
      :ok = PluginRegistry.attach(reg, SimplePlugin, %{"greeting" => "Hello"})
      assert {:error, :already_attached} = PluginRegistry.attach(reg, SimplePlugin, %{"greeting" => "Hi"})
    end

    test "rejects missing required config", %{reg: reg} do
      assert {:error, {:config_invalid, errors}} = PluginRegistry.attach(reg, SimplePlugin, %{})
      assert ["missing required config: greeting"] = errors
    end

    test "accepts empty config when all fields are optional", %{reg: reg} do
      assert :ok = PluginRegistry.attach(reg, OptionalConfigPlugin, %{})
    end

    test "returns init error", %{reg: reg} do
      assert {:error, {:init_failed, :init_boom}} = PluginRegistry.attach(reg, FailingPlugin)
    end
  end

  describe "detach/2" do
    test "removes plugin and its tools", %{reg: reg, wb: wb} do
      :ok = PluginRegistry.attach(reg, SimplePlugin, %{"greeting" => "Hello"})
      assert length(Workbench.list_tools(wb)) == 1

      assert :ok = PluginRegistry.detach(reg, "simple")
      assert Workbench.list_tools(wb) == []
    end

    test "returns error for unknown plugin", %{reg: reg} do
      assert {:error, :not_attached} = PluginRegistry.detach(reg, "nonexistent")
    end
  end

  describe "list_attached/1" do
    test "returns empty list initially", %{reg: reg} do
      assert PluginRegistry.list_attached(reg) == []
    end

    test "returns attached plugins", %{reg: reg} do
      :ok = PluginRegistry.attach(reg, SimplePlugin, %{"greeting" => "Hello"})
      :ok = PluginRegistry.attach(reg, OptionalConfigPlugin)

      plugins = PluginRegistry.list_attached(reg)
      names = Enum.map(plugins, & &1.name) |> Enum.sort()
      assert names == ["optional", "simple"]
    end
  end

  describe "get_plugin/2" do
    test "returns plugin info", %{reg: reg} do
      :ok = PluginRegistry.attach(reg, SimplePlugin, %{"greeting" => "Hello"})

      assert {:ok, %PluginInfo{} = info} = PluginRegistry.get_plugin(reg, "simple")
      assert info.name == "simple"
      assert info.version == "1.0.0"
      assert info.tool_names == ["simple.say_hello"]
      assert info.module == SimplePlugin
    end

    test "returns :not_found for unknown plugin", %{reg: reg} do
      assert :not_found = PluginRegistry.get_plugin(reg, "nonexistent")
    end
  end
end
