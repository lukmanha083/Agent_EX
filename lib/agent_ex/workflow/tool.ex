defmodule AgentEx.Workflow.Tool do
  @moduledoc """
  Wrap a workflow as a `Tool.t()` for composability.

  A saved workflow becomes callable as a tool — both from the chat orchestrator
  and from other workflows. Parameters are inferred from the trigger node config.
  """

  alias AgentEx.{Workflow, Workflows}
  alias AgentEx.Workflow.Runner

  @doc """
  Convert a workflow into a callable `AgentEx.Tool`.

  ## Options
  - `:tools` — tools available to `:tool` nodes within the workflow
  - `:agent_runner` — function for `:agent` nodes within the workflow
  """
  def to_tool(%Workflow{} = workflow, opts \\ []) do
    params = trigger_params_to_schema(workflow)

    AgentEx.Tool.new(
      name: "workflow_#{workflow.id}",
      description: workflow.description || "Run workflow: #{workflow.name}",
      kind: :write,
      parameters: params,
      function: fn args ->
        case Runner.run(workflow, args, opts) do
          {:ok, %{output: output}} ->
            {:ok, format_output(output)}

          {:error, %{node_id: node_id, reason: reason}} ->
            {:error, "Workflow failed at #{node_id}: #{inspect(reason)}"}
        end
      end
    )
  end

  @doc "Wrap all workflows for a project as tools."
  def workflows_as_tools(project_id, opts \\ []) do
    Workflows.list_workflows(project_id)
    |> Enum.map(&to_tool(&1, opts))
  end

  # --- Private ---

  defp trigger_params_to_schema(%Workflow{nodes: nodes}) do
    case Enum.find(nodes, &(&1.type == :trigger)) do
      nil -> empty_schema()
      %{config: config} -> build_trigger_schema(config["parameters"] || [])
    end
  end

  defp build_trigger_schema(params) do
    properties = Map.new(params, &param_to_property/1)

    required =
      params
      |> Enum.filter(&(&1["required"] == true || &1[:required] == true))
      |> Enum.map(&(&1["name"] || &1[:name]))

    %{"type" => "object", "properties" => properties, "required" => required}
  end

  defp param_to_property(param) do
    name = param["name"] || param[:name]
    type = param["type"] || param[:type] || "string"
    desc = param["description"] || param[:description]

    prop = %{"type" => type}
    prop = if desc, do: Map.put(prop, "description", desc), else: prop
    {name, prop}
  end

  defp empty_schema, do: %{"type" => "object", "properties" => %{}, "required" => []}

  defp format_output(output) when is_binary(output), do: output
  defp format_output(output), do: Jason.encode!(output)
end
