defmodule AgentEx.Memory.ProceduralMemory.Loader do
  @moduledoc """
  Handles DETS -> ETS hydration on startup and ETS -> DETS sync on interval.
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

    Logger.info("ProceduralMemory: hydrated #{count} skills from DETS")
    :ok
  end

  def sync(ets_table, dets_table) do
    count =
      :ets.foldl(
        fn {key, value}, acc ->
          :dets.insert(dets_table, {key, value})
          acc + 1
        end,
        0,
        ets_table
      )

    case :dets.sync(dets_table) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ProceduralMemory: DETS sync failed (#{count} entries): #{inspect(reason)}"
        )

        :ok
    end
  end
end
