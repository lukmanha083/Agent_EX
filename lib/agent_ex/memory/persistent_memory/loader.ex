defmodule AgentEx.Memory.PersistentMemory.Loader do
  @moduledoc """
  Handles DETS → ETS hydration on startup and ETS → DETS sync on interval.
  """

  require Logger

  def hydrate(ets_table, dets_table) do
    count =
      :dets.foldl(
        fn {key, value}, acc ->
          :ets.insert(ets_table, {key, value})
          acc + 1
        end,
        0,
        dets_table
      )

    Logger.info("PersistentMemory: hydrated #{count} entries from DETS")
    :ok
  end

  def sync(ets_table, dets_table) do
    :ets.foldl(
      fn {key, value}, acc ->
        :dets.insert(dets_table, {key, value})
        acc + 1
      end,
      0,
      ets_table
    )

    :dets.sync(dets_table)
    :ok
  end
end
