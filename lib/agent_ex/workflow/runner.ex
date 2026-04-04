defmodule AgentEx.Workflow.Runner do
  @moduledoc """
  Executes a workflow DAG deterministically. No LLM calls unless an
  `:agent` node is encountered. Data flows as JSON maps between nodes.

  Execution:
  1. Topological sort of nodes from trigger → output
  2. Execute each node with its input data
  3. Route output to connected nodes via edges
  4. Branch/merge as defined by flow control operators
  5. Collect output node results

  Broadcasts execution events via Phoenix.PubSub for real-time UI updates.
  """

  alias AgentEx.Workflow
  alias AgentEx.Workflow.Operators

  require Logger

  @type run_state :: %{
          run_id: String.t(),
          results: %{String.t() => term()},
          skipped: MapSet.t(),
          tools: [AgentEx.Tool.t()],
          agent_runner: (String.t(), String.t() -> {:ok, term()} | {:error, term()}) | nil
        }

  @doc """
  Execute a workflow with optional trigger data.

  ## Options
  - `:run_id` — unique execution ID (auto-generated if not provided)
  - `:tools` — list of `Tool.t()` available to `:tool` nodes
  - `:agent_runner` — `fn(agent_id, task) -> {:ok, result} | {:error, reason}` for `:agent` nodes
  """
  def run(%Workflow{} = workflow, trigger_data \\ %{}, opts \\ []) do
    run_id = opts[:run_id] || generate_run_id()

    case topological_sort(workflow.nodes, workflow.edges) do
      {:ok, sorted_ids} ->
        node_map = Map.new(workflow.nodes, &{&1.id, &1})
        edges_by_source = group_edges_by_source(workflow.edges)
        edges_by_target = group_edges_by_target(workflow.edges)

        state = %{
          run_id: run_id,
          results: %{},
          skipped: MapSet.new(),
          tools: opts[:tools] || [],
          agent_runner: opts[:agent_runner]
        }

        broadcast(run_id, :workflow_start, %{
          workflow_id: workflow.id,
          node_count: length(sorted_ids)
        })

        result =
          execute_dag(sorted_ids, node_map, edges_by_source, edges_by_target, trigger_data, state)

        case result do
          {:ok, state} ->
            output = collect_outputs(workflow.nodes, sorted_ids, state.results)
            broadcast(run_id, :workflow_complete, %{output: output})
            {:ok, %{run_id: run_id, results: state.results, output: output}}

          {:error, node_id, reason} ->
            broadcast(run_id, :workflow_error, %{node_id: node_id, error: reason})
            {:error, %{run_id: run_id, node_id: node_id, reason: reason}}
        end

      {:error, :cycle} ->
        {:error, %{run_id: run_id, node_id: nil, reason: "workflow contains a cycle"}}
    end
  end

  # --- DAG Execution ---

  defp execute_dag([], _nodes, _edges_src, _edges_tgt, _trigger, state), do: {:ok, state}

  defp execute_dag([node_id | rest], nodes, edges_src, edges_tgt, trigger, state) do
    if MapSet.member?(state.skipped, node_id) do
      execute_dag(rest, nodes, edges_src, edges_tgt, trigger, state)
    else
      node = Map.fetch!(nodes, node_id)
      input = gather_input(node, edges_tgt, trigger, state)

      broadcast(state.run_id, :node_start, %{node_id: node_id, type: node.type})

      context = %{
        results: state.results,
        tools: state.tools,
        agent_runner: state.agent_runner
      }

      case Operators.execute(node, input, context) do
        {:ok, output} ->
          state = put_in(state.results[node_id], output)
          broadcast(state.run_id, :node_complete, %{node_id: node_id, output: summarize(output)})
          execute_dag(rest, nodes, edges_src, edges_tgt, trigger, state)

        {:branch, port, output} ->
          state = put_in(state.results[node_id], output)
          broadcast(state.run_id, :node_branch, %{node_id: node_id, port: port})

          # Mark nodes on non-taken branches as skipped
          state = skip_untaken_branches(node_id, port, edges_src, nodes, state)
          execute_dag(rest, nodes, edges_src, edges_tgt, trigger, state)

        {:error, reason} ->
          broadcast(state.run_id, :node_error, %{node_id: node_id, error: reason})
          {:error, node_id, reason}
      end
    end
  end

  # --- Input Gathering ---

  defp gather_input(node, edges_by_target, trigger, state) do
    if node.type == :trigger do
      trigger
    else
      incoming = Map.get(edges_by_target, node.id, [])

      case incoming do
        [] -> %{}
        [single] -> Map.get(state.results, single.source_node_id, %{})
        multiple -> gather_multiple(multiple, node.type, state.results)
      end
    end
  end

  defp gather_multiple(edges, :merge, results) do
    Enum.map(edges, &Map.get(results, &1.source_node_id, %{}))
  end

  defp gather_multiple(edges, _type, results) do
    edges
    |> Enum.map(&Map.get(results, &1.source_node_id, %{}))
    |> Enum.reduce(%{}, fn
      m, acc when is_map(m) -> Map.merge(acc, m)
      _, acc -> acc
    end)
  end

  # --- Branch Skipping ---

  defp skip_untaken_branches(node_id, taken_port, edges_src, nodes, state) do
    outgoing = Map.get(edges_src, node_id, [])

    # Compute nodes reachable via the taken branch
    taken_edges = Enum.filter(outgoing, &(&1.source_port == taken_port))

    taken_reachable =
      Enum.reduce(taken_edges, MapSet.new(), fn edge, acc ->
        downstream = collect_downstream(edge.target_node_id, edges_src, nodes)
        Enum.reduce(downstream, acc, &MapSet.put(&2, &1))
      end)

    # Find edges whose port was NOT taken
    skipped_edges = Enum.filter(outgoing, &(&1.source_port != taken_port))

    # Collect downstream from skipped edges, but exclude nodes also reachable via taken
    skipped_ids =
      Enum.flat_map(skipped_edges, fn edge ->
        collect_downstream(edge.target_node_id, edges_src, nodes)
      end)

    skipped_set =
      skipped_ids
      |> Enum.reject(&MapSet.member?(taken_reachable, &1))
      |> Enum.reduce(state.skipped, &MapSet.put(&2, &1))

    %{state | skipped: skipped_set}
  end

  defp collect_downstream(node_id, edges_src, nodes) do
    downstream = Map.get(edges_src, node_id, [])
    # Don't follow into merge nodes (they have other incoming edges)
    node = Map.get(nodes, node_id)

    if node && node.type == :merge do
      # Don't skip merge nodes — they wait for all branches
      []
    else
      [
        node_id
        | Enum.flat_map(downstream, &collect_downstream(&1.target_node_id, edges_src, nodes))
      ]
    end
  end

  # --- Output Collection ---

  defp collect_outputs(nodes, sorted_ids, results) do
    output_nodes = Enum.filter(nodes, &(&1.type == :output))

    case output_nodes do
      [] ->
        # No explicit output node — return the topologically-last node's result
        last_id = List.last(sorted_ids)
        Map.get(results, last_id, %{})

      [single] ->
        Map.get(results, single.id, %{})

      multiple ->
        Map.new(multiple, fn node -> {node.id, Map.get(results, node.id, %{})} end)
    end
  end

  # --- Topological Sort (Kahn's algorithm) ---

  @doc "Topological sort of workflow nodes. Returns {:ok, sorted_ids} or {:error, :cycle}."
  def topological_sort(nodes, edges) do
    node_ids = MapSet.new(nodes, & &1.id)

    # Build adjacency + in-degree
    {adj, in_degree} =
      Enum.reduce(edges, {%{}, Map.new(node_ids, &{&1, 0})}, fn edge, {adj, deg} ->
        adj =
          Map.update(adj, edge.source_node_id, [edge.target_node_id], &[edge.target_node_id | &1])

        deg = Map.update(deg, edge.target_node_id, 1, &(&1 + 1))
        {adj, deg}
      end)

    # Start with nodes that have in-degree 0
    queue =
      in_degree
      |> Enum.filter(fn {_id, deg} -> deg == 0 end)
      |> Enum.map(fn {id, _} -> id end)
      |> :queue.from_list()

    kahn_loop(queue, adj, in_degree, [])
  end

  defp kahn_loop(queue, adj, in_degree, sorted) do
    case :queue.out(queue) do
      {:empty, _} ->
        if length(sorted) == map_size(in_degree) do
          {:ok, Enum.reverse(sorted)}
        else
          {:error, :cycle}
        end

      {{:value, node_id}, queue} ->
        neighbors = Map.get(adj, node_id, [])
        {queue, in_degree} = process_neighbors(neighbors, queue, in_degree)
        kahn_loop(queue, adj, in_degree, [node_id | sorted])
    end
  end

  defp process_neighbors(neighbors, queue, in_degree) do
    Enum.reduce(neighbors, {queue, in_degree}, fn neighbor, {q, deg} ->
      new_deg = Map.get(deg, neighbor, 0) - 1
      deg = Map.put(deg, neighbor, new_deg)
      q = if new_deg == 0, do: :queue.in(neighbor, q), else: q
      {q, deg}
    end)
  end

  # --- Edge Grouping ---

  defp group_edges_by_source(edges) do
    Enum.group_by(edges, & &1.source_node_id)
  end

  defp group_edges_by_target(edges) do
    Enum.group_by(edges, & &1.target_node_id)
  end

  # --- Broadcasting ---

  defp broadcast(run_id, event_type, payload) do
    Phoenix.PubSub.broadcast(
      AgentEx.PubSub,
      "workflow_run:#{run_id}",
      {event_type, payload}
    )
  rescue
    err ->
      Logger.debug("Workflow.Runner.broadcast/3 failed: #{Exception.format(:error, err)}")
      :ok
  end

  defp summarize(output) when is_binary(output) and byte_size(output) > 200 do
    String.slice(output, 0, 200) <> "..."
  end

  defp summarize(output) when is_map(output), do: Map.keys(output)
  defp summarize(output), do: output

  defp generate_run_id do
    "wfr-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
  end
end
