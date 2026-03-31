defmodule AgentEx.Plugins.SystemInfo do
  @moduledoc """
  Built-in plugin for system introspection tools.

  Provides safe, read-only access to system information: environment
  variables, working directory, current datetime, disk usage, and
  hardware specifications (CPU, RAM, OS, architecture).

  ## Config

  - `"allowed_env_vars"` — list of env var names the agent can read (deny-all if omitted)
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
      disk_usage_tool(),
      system_specs_tool()
    ]

    {:ok, tools}
  end

  defp env_var_tool(allowed_env_vars) do
    description =
      case allowed_env_vars do
        nil ->
          "Read an environment variable. No variables are currently allowed (configure allowed_env_vars)."

        [] ->
          "Read an environment variable. No variables are currently allowed (configure allowed_env_vars)."

        vars ->
          "Read an environment variable. Allowed: #{Enum.join(vars, ", ")}"
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
      description: "Get the current date and time in UTC.",
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
      description: "Get disk space usage for a path. Returns total, free, and used space.",
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

  defp system_specs_tool do
    Tool.new(
      name: "specs",
      description:
        "Get system hardware and OS specifications: CPU model, core count, " <>
          "total/free RAM, OS name and version, architecture, and hostname.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      },
      kind: :read,
      function: fn _args ->
        specs = %{
          "os" => os_info(),
          "architecture" => to_string(:erlang.system_info(:system_architecture)),
          "cpu_cores" => System.schedulers_online(),
          "cpu_model" => cpu_model(),
          "ram_total" => ram_total(),
          "ram_free" => ram_free(),
          "hostname" => hostname(),
          "erlang_version" => to_string(:erlang.system_info(:otp_release)),
          "elixir_version" => System.version()
        }

        {:ok, Jason.encode!(specs, pretty: true)}
      end
    )
  end

  # --- Helpers ---

  defp check_env_allowed(_name, nil),
    do: {:error, "No environment variables are allowed (configure allowed_env_vars)"}

  defp check_env_allowed(name, allowed) do
    if name in allowed do
      :ok
    else
      {:error, "Environment variable '#{name}' not in allowed list"}
    end
  end

  defp disk_usage_via_df(path) do
    if File.exists?(path) do
      {df_args, block_size} =
        case :os.type() do
          {:unix, :darwin} -> {["-k", path], 1024}
          {:unix, _} -> {["-B1", path], 1}
          _ -> {[path], 1}
        end

      case System.cmd("df", df_args, stderr_to_stdout: true) do
        {output, 0} -> parse_df_output(output, path, block_size)
        {error, _} -> {:error, "df command failed: #{error}"}
      end
    else
      {:error, "Path does not exist: #{path}"}
    end
  end

  defp parse_df_output(output, path, block_size) do
    with [_header, data | _] <- String.split(output, "\n", trim: true),
         [_fs, total, used, free, pct | _] <- String.split(data, ~r/\s+/) do
      info = %{
        "mount" => path,
        "total" => format_bytes(parse_int(total) * block_size),
        "used" => format_bytes(parse_int(used) * block_size),
        "free" => format_bytes(parse_int(free) * block_size),
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

  # --- System specs helpers (cross-platform) ---

  defp os_info do
    case :os.type() do
      {:unix, :darwin} -> "macOS #{os_version_cmd("sw_vers", ["-productVersion"])}"
      {:unix, :linux} -> "Linux #{os_version_cmd("uname", ["-r"])}"
      {:win32, _} -> "Windows #{os_version_cmd("cmd", ["/c", "ver"])}"
      {family, name} -> "#{family}/#{name}"
    end
  end

  defp os_version_cmd(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp cpu_model do
    case :os.type() do
      {:unix, :linux} -> read_proc_field("/proc/cpuinfo", "model name")
      {:unix, :darwin} -> sysctl_value("machdep.cpu.brand_string")
      _ -> "unknown"
    end
  end

  defp ram_total do
    case :os.type() do
      {:unix, :linux} ->
        case read_proc_field("/proc/meminfo", "MemTotal") do
          "unknown" -> "unknown"
          value -> parse_meminfo_kb(value)
        end

      {:unix, :darwin} ->
        case sysctl_value("hw.memsize") do
          "unknown" -> "unknown"
          bytes -> format_bytes(parse_int(bytes))
        end

      _ ->
        format_bytes(:erlang.memory(:total))
    end
  end

  defp ram_free do
    case :os.type() do
      {:unix, :linux} ->
        case read_proc_field("/proc/meminfo", "MemAvailable") do
          "unknown" -> "unknown"
          value -> parse_meminfo_kb(value)
        end

      {:unix, :darwin} ->
        # Free pages * page size
        case System.cmd("vm_stat", [], stderr_to_stdout: true) do
          {output, 0} -> parse_vm_stat_free(output)
          _ -> "unknown"
        end

      _ ->
        "unknown"
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end

  defp read_proc_field(path, field_name) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.find_value("unknown", &extract_field(&1, field_name))

      _ ->
        "unknown"
    end
  end

  defp extract_field(line, field_name) do
    case String.split(line, ":", parts: 2) do
      [key, value] -> if String.trim(key) == field_name, do: String.trim(value)
      _ -> nil
    end
  end

  defp sysctl_value(key) do
    case System.cmd("sysctl", ["-n", key], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp parse_meminfo_kb(value) do
    # MemTotal: 16384000 kB
    case Integer.parse(String.trim(value)) do
      {kb, _} -> format_bytes(kb * 1024)
      :error -> value
    end
  end

  defp parse_vm_stat_free(output) do
    pages =
      output
      |> String.split("\n")
      |> Enum.find_value(0, fn line ->
        if String.contains?(line, "Pages free") do
          line |> String.replace(~r/[^\d]/, "") |> parse_int()
        end
      end)

    # macOS page size is typically 16384 on Apple Silicon, 4096 on Intel
    page_size =
      case System.cmd("pagesize", [], stderr_to_stdout: true) do
        {ps, 0} -> parse_int(String.trim(ps))
        _ -> 4096
      end

    format_bytes(pages * page_size)
  rescue
    _ -> "unknown"
  end
end
