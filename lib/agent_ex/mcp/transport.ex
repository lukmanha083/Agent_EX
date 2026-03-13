defmodule AgentEx.MCP.Transport do
  @moduledoc """
  Transport adapters for MCP JSON-RPC 2.0 communication.

  Supports two transports:
  - **Stdio** — communicates with a subprocess via stdin/stdout using Erlang ports
  - **HTTP** — communicates with an HTTP endpoint using Req
  """

  @callback send_request(state :: term(), request :: map()) ::
              {:ok, map(), term()} | {:error, term()}
  @callback close(state :: term()) :: :ok

  defmodule Stdio do
    @moduledoc "Stdio transport — spawns a subprocess and communicates via stdin/stdout."
    @behaviour AgentEx.MCP.Transport

    defstruct [:port, buffer: ""]

    @doc "Open a stdio transport by spawning the given command."
    @spec open(String.t()) :: {:ok, %__MODULE__{}} | {:error, term()}
    def open(command) when is_binary(command) do
      [cmd | args] = String.split(command)

      case System.find_executable(cmd) do
        nil ->
          {:error, {:executable_not_found, cmd}}

        executable ->
          port =
            Port.open({:spawn_executable, executable}, [
              :binary,
              :stream,
              :exit_status,
              {:args, args},
              {:line, 1_048_576}
            ])

          {:ok, %__MODULE__{port: port}}
      end
    end

    @impl true
    def send_request(%__MODULE__{port: port} = state, request) do
      json = Jason.encode!(request) <> "\n"
      Port.command(port, json)

      receive do
        {^port, {:data, {:eol, line}}} ->
          case Jason.decode(line) do
            {:ok, response} -> {:ok, response, state}
            {:error, reason} -> {:error, {:json_decode, reason}}
          end

        {^port, {:exit_status, code}} ->
          {:error, {:process_exited, code}}
      after
        30_000 -> {:error, :timeout}
      end
    end

    @impl true
    def close(%__MODULE__{port: port}) do
      Port.close(port)
      :ok
    rescue
      _ -> :ok
    end
  end

  defmodule HTTP do
    @moduledoc "HTTP transport — sends JSON-RPC requests to an HTTP endpoint."
    @behaviour AgentEx.MCP.Transport

    defstruct [:url]

    @doc "Open an HTTP transport to the given URL."
    @spec open(String.t()) :: {:ok, %__MODULE__{}}
    def open(url) when is_binary(url) do
      {:ok, %__MODULE__{url: url}}
    end

    @impl true
    def send_request(%__MODULE__{url: url} = state, request) do
      case Req.post(url, json: request) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body, state}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def close(%__MODULE__{}), do: :ok
  end
end
