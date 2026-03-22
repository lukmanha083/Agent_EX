defmodule AgentEx.Timezone do
  @moduledoc """
  Timezone helper for converting UTC timestamps to user-local time.

  Uses IANA timezone strings (e.g. "Asia/Jakarta") and the `tz` library
  as the timezone database for Elixir's Calendar system.

  Timezone identifiers are parsed at compile time from the IANA zone1970.tab
  bundled with the `tz` dependency.
  """

  @default_timezone "Etc/UTC"

  # Find zone1970.tab from tz's priv directory at compile time.
  # Tz.IanaDataDir.dir() points to the versioned subdirectory (e.g. priv/tzdata2024b).
  @external_resource zone_tab = Path.join(Tz.IanaDataDir.dir(), "zone1970.tab")

  # Fallback: scan deps source when build dir doesn't have it yet
  @zone_tab_path (if File.exists?(zone_tab) do
                    zone_tab
                  else
                    Path.wildcard(Path.join([__DIR__, "../../deps/tz/priv/*/zone1970.tab"]))
                    |> List.first()
                  end)

  @zone_identifiers (if @zone_tab_path do
                       @zone_tab_path
                       |> File.read!()
                       |> String.split("\n")
                       |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
                       |> Enum.map(fn line ->
                         line |> String.split("\t") |> Enum.at(2)
                       end)
                       |> Enum.reject(&is_nil/1)
                     else
                       []
                     end)
                    |> Enum.concat(["Etc/UTC"])
                    |> Enum.uniq()
                    |> Enum.sort()

  @doc "Returns the default timezone."
  @spec default() :: String.t()
  def default, do: @default_timezone

  @doc """
  Convert a UTC DateTime to the user's local timezone.

  Falls back to UTC if the timezone is nil or invalid.
  """
  @spec to_local(DateTime.t(), String.t() | nil) :: DateTime.t()
  def to_local(utc_datetime, nil), do: to_local(utc_datetime, @default_timezone)

  def to_local(%DateTime{} = utc_datetime, timezone) when is_binary(timezone) do
    case DateTime.shift_zone(utc_datetime, timezone) do
      {:ok, local} -> local
      {:error, _} -> utc_datetime
    end
  end

  @doc """
  List all IANA timezones grouped by region.

  Returns a sorted list of `{region, [timezone]}` tuples.
  """
  @spec grouped_timezones() :: [{String.t(), [String.t()]}]
  def grouped_timezones do
    @zone_identifiers
    |> Enum.filter(&String.contains?(&1, "/"))
    |> Enum.group_by(fn tz -> tz |> String.split("/") |> hd() end)
    |> Enum.sort_by(fn {region, _} -> region end)
    |> Enum.map(fn {region, zones} -> {region, Enum.sort(zones)} end)
  end

  @doc """
  List all IANA timezones as a flat sorted list.
  """
  @spec all_timezones() :: [String.t()]
  def all_timezones, do: @zone_identifiers

  @doc """
  Validate that a timezone string is a known IANA timezone.
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(timezone) when is_binary(timezone) do
    timezone in @zone_identifiers
  end

  def valid?(_), do: false

  @doc """
  Get display label for a timezone (e.g. "Asia/Jakarta (UTC+07:00)").
  """
  @spec label(String.t()) :: String.t()
  def label(timezone) when is_binary(timezone) do
    now = DateTime.utc_now()

    case DateTime.shift_zone(now, timezone) do
      {:ok, local} ->
        offset = format_offset(local.utc_offset + local.std_offset)
        "#{timezone} (UTC#{offset})"

      {:error, _} ->
        timezone
    end
  end

  @doc """
  List all timezones as `{value, label}` tuples for use in select dropdowns.
  """
  @spec select_options() :: [{String.t(), String.t()}]
  def select_options do
    grouped_timezones()
    |> Enum.flat_map(fn {_region, zones} ->
      Enum.map(zones, fn tz -> {tz, label(tz)} end)
    end)
  end

  defp format_offset(seconds) do
    sign = if seconds >= 0, do: "+", else: "-"
    abs_seconds = abs(seconds)
    hours = div(abs_seconds, 3600)
    minutes = div(rem(abs_seconds, 3600), 60)

    "#{sign}#{String.pad_leading(Integer.to_string(hours), 2, "0")}:#{String.pad_leading(Integer.to_string(minutes), 2, "0")}"
  end
end
