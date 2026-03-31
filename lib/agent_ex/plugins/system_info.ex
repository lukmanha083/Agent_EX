defmodule AgentEx.Plugins.SystemInfo do
  @moduledoc """
  Built-in plugin for system introspection tools.

  Provides safe, read-only access to system information: environment
  variables, working directory, current datetime, and disk usage.

  ## Config

  - `"allowed_env_vars"` — list of env var names the agent can read (optional, allows all if omitted)
  - `"working_dir"` — working directory to report (optional, default: cwd)
  """

  @behaviour AgentEx.ToolPlugin

  alias AgentEx.Tool

  @impl true
  def manifest do
    %{
      name: "system",
      version: "1.0.0",
      description: "System introspection tools",
      config_schema: [
        {:allowed_env_vars, {:array, :string}, "List of env var names agent can read",
         optional: true},
        {:working_dir, :string, "Working directory to report", optional: true}
      ]
    }
  end

  @impl true
  def init(config) do
    allowed_env_vars = Map.get(config, "allowed_env_vars")
    working_dir = Map.get(config, "working_dir")

    tools = [
      env_var_tool(allowed_env_vars),
      cwd_tool(working_dir),
      datetime_tool(),
      disk_usage_tool()
    ]

    {:ok, tools}
  end

  defp env_var_tool(allowed_env_vars) do
    description =
      case allowed_env_vars do
        nil -> "Read an environment variable."
        vars -> "Read an environment variable. Allowed: #{Enum.join(vars, ", ")}"
      end

    Tool.new(
      name: "env_var",
      description: description,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "Environment variable name"
          }
        },
        "required" => ["name"]
      },
      kind: :read,
      function: fn %{"name" => name} ->
        with :ok <- check_env_allowed(name, allowed_env_vars) do
          case System.get_env(name) do
            nil -> {:ok, "Not set"}
            value -> {:ok, value}
          end
        end
      end
    )
  end

  defp cwd_tool(configured_dir) do
    Tool.new(
      name: "cwd",
      description: "Get the current working directory.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      },
      kind: :read,
      function: fn _args ->
        dir = configured_dir || File.cwd!()
        {:ok, dir}
      end
    )
  end

  defp datetime_tool do
    Tool.new(
      name: "datetime",
      description:
        "Get the current date and time in UTC, with optional timezone conversion.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "format" => %{
            "type" => "string",
            "enum" => ["iso8601", "date", "time", "unix"],
            "description" => "Output format (default: iso8601)"
          }
        },
        "required" => []
      },
      kind: :read,
      function: fn args ->
        format = Map.get(args, "format", "iso8601")
        now = DateTime.utc_now()

        result =
          case format do
            "iso8601" -> DateTime.to_iso8601(now)
            "date" -> Date.to_iso8601(DateTime.to_date(now))
            "time" -> Time.to_iso8601(DateTime.to_time(now))
            "unix" -> Integer.to_string(DateTime.to_unix(now))
            _ -> DateTime.to_iso8601(now)
          end

        {:ok, result}
      end
    )
  end

  defp disk_usage_tool do
    Tool.new(
      name: "disk_usage",
      description:
        "Get disk space usage for a path. Returns total, free, and used space.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to check disk usage for (default: /)"
          }
        },
        "required" => []
      },
      kind: :read,
      function: fn args ->
        path = Map.get(args, "path", "/")
        disk_usage_via_df(path)
      end
    )
  end

  # --- Helpers ---

  defp check_env_allowed(_name, nil), do: :ok

  defp check_env_allowed(name, allowed) do
    if name in allowed do
      :ok
    else
      {:error, "Environment variable '#{name}' not in allowed list"}
    end
  end

  defp disk_usage_via_df(path) do
    case System.cmd("df", ["-B1", path], stderr_to_stdout: true) do
      {output, 0} -> parse_df_output(output, path)
      {error, _} -> {:error, "df command failed: #{error}"}
    end
  end

  defp parse_df_output(output, path) do
    with [_header, data | _] <- String.split(output, "\n", trim: true),
         [_fs, total, used, free, pct | _] <- String.split(data, ~r/\s+/) do
      info = %{
        "mount" => path,
        "total" => format_bytes(parse_int(total)),
        "used" => format_bytes(parse_int(used)),
        "free" => format_bytes(parse_int(free)),
        "percent_used" => String.replace(pct, "%", "") |> parse_int()
      }

      {:ok, Jason.encode!(info, pretty: true)}
    else
      _ -> {:error, "Could not parse df output"}
    end
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp format_bytes(bytes) when bytes >= 1_073_741_824 do
    "#{Float.round(bytes / 1_073_741_824, 2)} GB"
  end

  defp format_bytes(bytes) when bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 2)} MB"
  end

  defp format_bytes(bytes) when bytes >= 1024 do
    "#{Float.round(bytes / 1024, 2)} KB"
  end

  defp format_bytes(bytes), do: "#{bytes} B"
end
