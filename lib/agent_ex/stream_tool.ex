defmodule AgentEx.StreamTool do
  @moduledoc """
  Tools that produce incremental results via streaming.

  Maps to AutoGen's `StreamTool` protocol with `run_json_stream` returning `AsyncGenerator`.
  The collector aggregates chunks; the final aggregated result is returned as a normal
  `FunctionResult` — transparent to the LLM.

  ## Streaming function signature

      fn args, emit ->
        emit.({:chunk, "partial result 1"})
        emit.({:chunk, "partial result 2"})
        emit.({:progress, 50})
        {:ok, "final result"}
      end

  ## Example

      stream_fn = fn %{"query" => q}, emit ->
        for i <- 1..3 do
          Process.sleep(100)
          emit.({:chunk, "result \#{i} for \#{q}"})
        end
        {:ok, "3 results found for \#{q}"}
      end

      tool = Tool.new(name: "search", description: "Search", parameters: %{},
        function: stream_fn)
      wrapped = StreamTool.wrap(tool)
      # Executes streaming function, collects chunks, returns final result
  """

  alias AgentEx.Tool

  @default_timeout 30_000
  @default_max_chunks 1_000

  @type chunk :: {:chunk, term()} | {:progress, number()}

  @doc """
  Wrap a streaming tool function into a standard tool.

  The original function must accept `(args, emit)` where emit is a callback.
  The wrapped tool function accepts only `args` and handles collection internally.

  ## Options
  - `:timeout` — max time in ms to wait for completion (default: 30_000)
  - `:max_chunks` — max chunks to collect (default: 1_000)
  - `:on_chunk` — optional callback `fn chunk -> :ok end` for side effects
  """
  @spec wrap(Tool.t(), keyword()) :: Tool.t()
  def wrap(%Tool{} = tool, opts \\ []) do
    stream_fn = tool.function
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_chunks = Keyword.get(opts, :max_chunks, @default_max_chunks)
    on_chunk = Keyword.get(opts, :on_chunk)

    wrapped_fn = fn args ->
      collect(stream_fn, args, timeout: timeout, max_chunks: max_chunks, on_chunk: on_chunk)
    end

    %Tool{tool | function: wrapped_fn}
  end

  @doc """
  Run a streaming function, collect chunks, and return the final result.

  ## Options
  - `:timeout` — max wait in ms (default: 30_000)
  - `:max_chunks` — max chunks (default: 1_000)
  - `:on_chunk` — optional callback for each chunk
  """
  @spec collect(function(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def collect(stream_fn, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_chunks = Keyword.get(opts, :max_chunks, @default_max_chunks)
    on_chunk = Keyword.get(opts, :on_chunk)

    collector = self()

    task =
      Task.async(fn ->
        emit = fn chunk ->
          send(collector, {:stream_chunk, self(), chunk})
          :ok
        end

        stream_fn.(args, emit)
      end)

    collect_loop(task, [], max_chunks, on_chunk, timeout)
  end

  defp collect_loop(task, chunks, max_chunks, _on_chunk, _timeout)
       when length(chunks) >= max_chunks do
    Task.shutdown(task, :brutal_kill)
    {:error, {:max_chunks_exceeded, max_chunks}}
  end

  defp collect_loop(task, chunks, max_chunks, on_chunk, timeout) do
    receive do
      {:stream_chunk, _pid, chunk} ->
        if on_chunk, do: on_chunk.(chunk)
        collect_loop(task, [chunk | chunks], max_chunks, on_chunk, timeout)

      {ref, result} when ref == task.ref ->
        # Task completed — drain any remaining chunks
        Process.demonitor(task.ref, [:flush])
        remaining = drain_chunks(task)
        if on_chunk, do: Enum.each(remaining, on_chunk)
        _all_chunks = Enum.reverse(remaining ++ chunks)

        result

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        {:error, {:stream_crashed, reason}}
    after
      timeout ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp drain_chunks(task) do
    receive do
      {:stream_chunk, _pid, chunk} -> [chunk | drain_chunks(task)]
    after
      0 -> []
    end
  end
end
