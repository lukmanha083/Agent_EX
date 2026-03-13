defmodule AgentEx.ToolOverrideTest do
  use ExUnit.Case, async: true

  alias AgentEx.{Tool, ToolOverride}

  setup do
    tool =
      Tool.new(
        name: "search_db",
        description: "Search the database",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"}
          },
          "required" => ["query"]
        },
        function: fn %{"query" => q} -> {:ok, "found: #{q}"} end,
        kind: :read
      )

    %{tool: tool}
  end

  describe "rename/2" do
    test "changes the tool name", %{tool: tool} do
      renamed = ToolOverride.rename(tool, "find_records")
      assert renamed.name == "find_records"
    end

    test "preserves the original kind", %{tool: tool} do
      renamed = ToolOverride.rename(tool, "find_records")
      assert renamed.kind == :read
    end

    test "preserves the description", %{tool: tool} do
      renamed = ToolOverride.rename(tool, "find_records")
      assert renamed.description == "Search the database"
    end

    test "preserves function execution", %{tool: tool} do
      renamed = ToolOverride.rename(tool, "find_records")
      assert {:ok, "found: test"} = Tool.execute(renamed, %{"query" => "test"})
    end
  end

  describe "redescribe/2" do
    test "changes the description", %{tool: tool} do
      updated = ToolOverride.redescribe(tool, "Find stuff in DB")
      assert updated.description == "Find stuff in DB"
    end

    test "preserves the name", %{tool: tool} do
      updated = ToolOverride.redescribe(tool, "Find stuff in DB")
      assert updated.name == "search_db"
    end
  end

  describe "wrap/2" do
    test "overrides multiple fields", %{tool: tool} do
      wrapped = ToolOverride.wrap(tool, name: "find", description: "Find things")
      assert wrapped.name == "find"
      assert wrapped.description == "Find things"
      assert wrapped.kind == :read
    end

    test "preserves kind for write tools" do
      write_tool =
        Tool.new(
          name: "delete_record",
          description: "Delete a record",
          parameters: %{},
          function: fn _ -> {:ok, "deleted"} end,
          kind: :write
        )

      wrapped = ToolOverride.wrap(write_tool, name: "remove_record")
      assert wrapped.kind == :write
      assert wrapped.name == "remove_record"
    end

    test "overridden tool executes correctly", %{tool: tool} do
      wrapped = ToolOverride.wrap(tool, name: "find", description: "Find")
      assert {:ok, "found: hello"} = Tool.execute(wrapped, %{"query" => "hello"})
    end

    test "overrides parameters", %{tool: tool} do
      new_params = %{"type" => "object", "properties" => %{}, "required" => []}
      wrapped = ToolOverride.wrap(tool, parameters: new_params)
      assert wrapped.parameters == new_params
    end
  end

  describe "original_name/1" do
    test "returns original name after wrapping", %{tool: tool} do
      wrapped = ToolOverride.rename(tool, "find_records")
      assert ToolOverride.original_name(wrapped) == "search_db"
    end

    test "returns nil for unwrapped tools", %{tool: tool} do
      assert ToolOverride.original_name(tool) == nil
    end
  end

  describe "schema generation" do
    test "wrapped tool generates correct schema", %{tool: tool} do
      wrapped = ToolOverride.rename(tool, "find_records")
      schema = Tool.to_schema(wrapped)

      assert schema["function"]["name"] == "find_records"
      assert schema["function"]["description"] == "Search the database"
    end
  end
end
