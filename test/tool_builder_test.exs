defmodule AgentEx.ToolBuilderTest do
  use ExUnit.Case, async: true

  alias AgentEx.{Tool, ToolBuilder}

  describe "build/1" do
    test "builds a tool with auto-generated schema" do
      tool =
        ToolBuilder.build(
          name: "get_weather",
          description: "Get weather for a city",
          params: [
            {:city, :string, "City name"},
            {:units, :string, "C or F", optional: true}
          ],
          function: fn %{"city" => city} -> {:ok, "Sunny in #{city}"} end
        )

      assert %Tool{name: "get_weather"} = tool
      assert tool.description == "Get weather for a city"
      assert tool.kind == :read

      params = tool.parameters
      assert params["type"] == "object"
      assert params["properties"]["city"]["type"] == "string"
      assert params["properties"]["city"]["description"] == "City name"
      assert params["properties"]["units"]["type"] == "string"
      assert params["required"] == ["city"]
    end

    test "builds a write tool" do
      tool =
        ToolBuilder.build(
          name: "delete_file",
          description: "Delete a file",
          params: [{:path, :string, "File path"}],
          function: fn _ -> {:ok, "deleted"} end,
          kind: :write
        )

      assert tool.kind == :write
    end

    test "built tool executes correctly" do
      tool =
        ToolBuilder.build(
          name: "add",
          description: "Add numbers",
          params: [{:a, :integer, "First"}, {:b, :integer, "Second"}],
          function: fn %{"a" => a, "b" => b} -> {:ok, a + b} end
        )

      assert {:ok, 5} = Tool.execute(tool, %{"a" => 2, "b" => 3})
    end
  end

  describe "params_to_schema/1" do
    test "simple string param" do
      schema = ToolBuilder.params_to_schema([{:name, :string, "The name"}])

      assert schema == %{
               "type" => "object",
               "properties" => %{
                 "name" => %{"type" => "string", "description" => "The name"}
               },
               "required" => ["name"]
             }
    end

    test "optional params excluded from required" do
      schema =
        ToolBuilder.params_to_schema([
          {:name, :string, "Name"},
          {:age, :integer, "Age", optional: true}
        ])

      assert schema["required"] == ["name"]
    end

    test "all primitive types" do
      schema =
        ToolBuilder.params_to_schema([
          {:s, :string, "string"},
          {:i, :integer, "int"},
          {:n, :number, "num"},
          {:b, :boolean, "bool"}
        ])

      assert schema["properties"]["s"]["type"] == "string"
      assert schema["properties"]["i"]["type"] == "integer"
      assert schema["properties"]["n"]["type"] == "number"
      assert schema["properties"]["b"]["type"] == "boolean"
    end

    test "enum type" do
      schema = ToolBuilder.params_to_schema([{:color, {:enum, ["red", "blue"]}, "Color"}])

      assert schema["properties"]["color"] == %{
               "type" => "string",
               "enum" => ["red", "blue"],
               "description" => "Color"
             }
    end

    test "array type" do
      schema = ToolBuilder.params_to_schema([{:tags, {:array, :string}, "Tags"}])

      assert schema["properties"]["tags"] == %{
               "type" => "array",
               "items" => %{"type" => "string"},
               "description" => "Tags"
             }
    end

    test "nested object type" do
      schema =
        ToolBuilder.params_to_schema([
          {:address, {:object, [{:city, :string, "City"}, {:zip, :string, "ZIP"}]}, "Address"}
        ])

      addr = schema["properties"]["address"]
      assert addr["type"] == "object"
      assert addr["properties"]["city"]["type"] == "string"
      assert addr["required"] == ["city", "zip"]
    end
  end

  describe "type_to_schema/1" do
    test "string" do
      assert ToolBuilder.type_to_schema(:string) == %{"type" => "string"}
    end

    test "integer" do
      assert ToolBuilder.type_to_schema(:integer) == %{"type" => "integer"}
    end

    test "number" do
      assert ToolBuilder.type_to_schema(:number) == %{"type" => "number"}
    end

    test "boolean" do
      assert ToolBuilder.type_to_schema(:boolean) == %{"type" => "boolean"}
    end

    test "enum" do
      assert ToolBuilder.type_to_schema({:enum, ["a", "b"]}) == %{
               "type" => "string",
               "enum" => ["a", "b"]
             }
    end

    test "array of integers" do
      assert ToolBuilder.type_to_schema({:array, :integer}) == %{
               "type" => "array",
               "items" => %{"type" => "integer"}
             }
    end
  end

  describe "deftool macro" do
    defmodule TestTools do
      import AgentEx.ToolBuilder

      deftool :greet, "Greet someone" do
        param :name, :string, "Person's name"
        param :greeting, :string, "Custom greeting", optional: true
      end

      def greet(%{"name" => name} = args) do
        greeting = Map.get(args, "greeting", "Hello")
        {:ok, "#{greeting}, #{name}!"}
      end
    end

    test "generates tool function" do
      tool = TestTools.greet_tool()
      assert %Tool{name: "greet"} = tool
      assert tool.description == "Greet someone"
    end

    test "generates correct schema" do
      tool = TestTools.greet_tool()
      assert tool.parameters["properties"]["name"]["type"] == "string"
      assert tool.parameters["required"] == ["name"]
      refute "greeting" in tool.parameters["required"]
    end

    test "generated tool executes via function reference" do
      tool = TestTools.greet_tool()
      assert {:ok, "Hello, World!"} = Tool.execute(tool, %{"name" => "World"})
      assert {:ok, "Hi, Bob!"} = Tool.execute(tool, %{"name" => "Bob", "greeting" => "Hi"})
    end
  end
end
