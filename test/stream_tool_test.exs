defmodule AgentEx.StreamToolTest do
  use ExUnit.Case, async: true

  alias AgentEx.{StreamTool, Tool}

  describe "wrap/2" do
    test "wraps a streaming tool into a standard tool" do
      stream_fn = fn %{"query" => q}, emit ->
        emit.({:chunk, "result 1"})
        emit.({:chunk, "result 2"})
        {:ok, "found 2 results for #{q}"}
      end

      tool =
        Tool.new(
          name: "search",
          description: "Search",
          parameters: %{},
          function: stream_fn
        )

      wrapped = StreamTool.wrap(tool)
      assert {:ok, "found 2 results for elixir"} = Tool.execute(wrapped, %{"query" => "elixir"})
    end

    test "preserves tool metadata" do
      tool =
        Tool.new(
          name: "search",
          description: "Stream search",
          parameters: %{"type" => "object"},
          function: fn _, _ -> {:ok, "done"} end,
          kind: :read
        )

      wrapped = StreamTool.wrap(tool)
      assert wrapped.name == "search"
      assert wrapped.description == "Stream search"
      assert wrapped.kind == :read
    end
  end

  describe "collect/3" do
    test "collects chunks and returns final result" do
      stream_fn = fn _args, emit ->
        emit.({:chunk, "a"})
        emit.({:chunk, "b"})
        {:ok, "done"}
      end

      assert {:ok, "done"} = StreamTool.collect(stream_fn, %{})
    end

    test "handles progress chunks" do
      chunks_received = :ets.new(:chunks, [:set, :public])

      stream_fn = fn _args, emit ->
        emit.({:progress, 50})
        emit.({:chunk, "data"})
        emit.({:progress, 100})
        {:ok, "complete"}
      end

      on_chunk = fn chunk ->
        key = System.unique_integer([:positive])
        :ets.insert(chunks_received, {key, chunk})
      end

      assert {:ok, "complete"} =
               StreamTool.collect(stream_fn, %{}, on_chunk: on_chunk)

      all_chunks = :ets.tab2list(chunks_received) |> Enum.map(&elem(&1, 1))
      assert {:progress, 50} in all_chunks
      assert {:chunk, "data"} in all_chunks
      :ets.delete(chunks_received)
    end

    test "handles error from stream function" do
      stream_fn = fn _args, emit ->
        emit.({:chunk, "partial"})
        {:error, "failed"}
      end

      assert {:error, "failed"} = StreamTool.collect(stream_fn, %{})
    end

    test "times out on long-running streams" do
      stream_fn = fn _args, _emit ->
        Process.sleep(10_000)
        {:ok, "never"}
      end

      assert {:error, :timeout} = StreamTool.collect(stream_fn, %{}, timeout: 100)
    end

    test "enforces max_chunks limit" do
      stream_fn = fn _args, emit ->
        for i <- 1..100 do
          emit.({:chunk, "chunk #{i}"})
        end

        {:ok, "done"}
      end

      assert {:error, {:max_chunks_exceeded, 5}} =
               StreamTool.collect(stream_fn, %{}, max_chunks: 5, timeout: 5_000)
    end

    test "on_chunk callback is invoked for each chunk" do
      parent = self()

      stream_fn = fn _args, emit ->
        emit.({:chunk, "first"})
        emit.({:chunk, "second"})
        {:ok, "done"}
      end

      on_chunk = fn chunk -> send(parent, {:got_chunk, chunk}) end

      assert {:ok, "done"} = StreamTool.collect(stream_fn, %{}, on_chunk: on_chunk)

      assert_receive {:got_chunk, {:chunk, "first"}}
      assert_receive {:got_chunk, {:chunk, "second"}}
    end
  end
end
