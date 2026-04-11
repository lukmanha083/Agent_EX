defmodule AgentEx.Plugins.Todo do
  @moduledoc """
  Built-in plugin for session-scoped task tracking.

  Provides tools for agents to manage a checklist during execution:
  add items, list them, update status, and delete. The list lives in a
  supervised GenServer and is lost when the plugin is detached (session-scoped).

  ## Example

      PluginRegistry.attach(reg, AgentEx.Plugins.Todo, %{})

      # Agent can now call:
      #   todo_add    %{"text" => "Validate input schema"}
      #   todo_list   %{}
      #   todo_update %{"id" => "1", "status" => "done"}
      #   todo_delete %{"id" => "1"}
  """

  @behaviour AgentEx.ToolPlugin

  alias AgentEx.Tool

  @valid_statuses ~w[pending in_progress done]

  @impl true
  def manifest do
    %{
      name: "todo",
      version: "1.0.0",
      description: "Session-scoped task checklist for agent self-management",
      config_schema: []
    }
  end

  @impl true
  def init(_config) do
    server_name = :"#{__MODULE__.Server}_#{:erlang.unique_integer([:positive])}"

    child_spec = %{
      id: __MODULE__.Server,
      start: {__MODULE__.Server, :start_link, [[name: server_name]]},
      restart: :temporary
    }

    tools = [
      add_tool(server_name),
      list_tool(server_name),
      update_tool(server_name),
      delete_tool(server_name)
    ]

    {:stateful, tools, child_spec}
  end

  @impl true
  def cleanup(pid) do
    if is_pid(pid) and Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    end

    :ok
  end

  # -- Tools --

  defp add_tool(server) do
    Tool.new(
      name: "add",
      description: "Add a new todo item to track work in progress.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "text" => %{
            "type" => "string",
            "description" => "Description of the task"
          }
        },
        "required" => ["text"]
      },
      kind: :write,
      function: fn %{"text" => text} ->
        GenServer.call(server, {:add, text})
      end
    )
  end

  defp list_tool(server) do
    Tool.new(
      name: "list",
      description: "List all todo items with their status.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      },
      kind: :read,
      function: fn _args ->
        GenServer.call(server, :list)
      end
    )
  end

  defp update_tool(server) do
    Tool.new(
      name: "update",
      description:
        "Update a todo item's status or text. " <>
          "Status transitions: pending -> in_progress -> done.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "Todo item ID"
          },
          "status" => %{
            "type" => "string",
            "enum" => ["pending", "in_progress", "done"],
            "description" => "New status"
          },
          "text" => %{
            "type" => "string",
            "description" => "Updated task description"
          }
        },
        "required" => ["id"]
      },
      kind: :write,
      function: fn args ->
        status = args["status"]

        if status && status not in @valid_statuses do
          {:error,
           "Invalid status '#{status}'. Must be one of: #{Enum.join(@valid_statuses, ", ")}"}
        else
          with {:ok, id} <- parse_id(args["id"]) do
            updates = Map.take(args, ["status", "text"])
            GenServer.call(server, {:update, id, updates})
          end
        end
      end
    )
  end

  defp delete_tool(server) do
    Tool.new(
      name: "delete",
      description: "Remove a todo item from the list.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "Todo item ID to delete"
          }
        },
        "required" => ["id"]
      },
      kind: :write,
      function: fn %{"id" => id} ->
        with {:ok, id} <- parse_id(id) do
          GenServer.call(server, {:delete, id})
        end
      end
    )
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "Invalid todo ID: #{inspect(id)}"}
    end
  end
end

defmodule AgentEx.Plugins.Todo.Server do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    {:ok, %{todos: %{}, next_id: 1}}
  end

  @impl true
  def handle_call({:add, text}, _from, state) do
    id = state.next_id

    todo = %{
      "text" => text,
      "status" => "pending",
      "created_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    new_state = %{
      state
      | todos: Map.put(state.todos, id, todo),
        next_id: id + 1
    }

    {:reply, {:ok, "Added todo ##{id}: #{text}"}, new_state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    if map_size(state.todos) == 0 do
      {:reply, {:ok, "No todos."}, state}
    else
      lines =
        state.todos
        |> Enum.sort_by(fn {id, _} -> id end)
        |> Enum.map_join("\n", fn {id, todo} ->
          "##{id} #{status_icon(todo["status"])} #{todo["text"]}"
        end)

      {:reply, {:ok, lines}, state}
    end
  end

  @impl true
  def handle_call({:update, id, updates}, _from, state) do
    case Map.fetch(state.todos, id) do
      {:ok, todo} ->
        updated = Map.merge(todo, updates)
        new_state = %{state | todos: Map.put(state.todos, id, updated)}
        {:reply, {:ok, "Updated todo ##{id}"}, new_state}

      :error ->
        {:reply, {:error, "Todo ##{id} not found"}, state}
    end
  end

  @impl true
  def handle_call({:delete, id}, _from, state) do
    case Map.fetch(state.todos, id) do
      {:ok, _todo} ->
        new_state = %{state | todos: Map.delete(state.todos, id)}
        {:reply, {:ok, "Deleted todo ##{id}"}, new_state}

      :error ->
        {:reply, {:error, "Todo ##{id} not found"}, state}
    end
  end

  defp status_icon("pending"), do: "[ ]"
  defp status_icon("in_progress"), do: "[~]"
  defp status_icon("done"), do: "[x]"
  defp status_icon(_other), do: "[?]"
end
