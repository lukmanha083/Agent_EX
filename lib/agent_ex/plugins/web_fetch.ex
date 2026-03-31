defmodule AgentEx.Plugins.WebFetch do
  @moduledoc """
  Built-in plugin for fetching web content with SSRF protection.

  Uses `Req` for HTTP requests and `AgentEx.NetworkPolicy` to block
  requests to internal/private network addresses.

  ## Config

  - `"allowed_domains"` — list of allowed domains (optional, allows all public if omitted)
  - `"timeout"` — request timeout in ms (optional, default: 15000)
  - `"max_body_size"` — max response body size in bytes (optional, default: 1_048_576)
  """

  @behaviour AgentEx.ToolPlugin

  alias AgentEx.Tool

  @default_timeout 15_000
  @default_max_body_size 1_048_576

  @impl true
  def manifest do
    %{
      name: "web",
      version: "1.0.0",
      description: "HTTP fetching with SSRF protection",
      config_schema: [
        {:allowed_domains, {:array, :string}, "List of allowed domains", optional: true},
        {:timeout, :integer, "Request timeout in ms", optional: true},
        {:max_body_size, :integer, "Max response body size in bytes", optional: true}
      ]
    }
  end

  @impl true
  def init(config) do
    allowed_domains = Map.get(config, "allowed_domains")
    timeout = Map.get(config, "timeout", @default_timeout)
    max_body_size = Map.get(config, "max_body_size", @default_max_body_size)

    tools = [
      fetch_url_tool(allowed_domains, timeout, max_body_size),
      fetch_json_tool(allowed_domains, timeout, max_body_size)
    ]

    {:ok, tools}
  end

  defp fetch_url_tool(allowed_domains, timeout, max_body_size) do
    Tool.new(
      name: "fetch_url",
      description:
        "Fetch the content of a URL. Returns the response body as text. " <>
          "Useful for reading web pages, APIs, and documentation.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" => "The URL to fetch (must be http:// or https://)"
          },
          "method" => %{
            "type" => "string",
            "enum" => ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD"],
            "description" => "HTTP method (default: GET)"
          },
          "headers" => %{
            "type" => "object",
            "description" => "Additional HTTP headers as key-value pairs"
          },
          "body" => %{
            "type" => "string",
            "description" => "Request body (for POST/PUT/PATCH)"
          }
        },
        "required" => ["url"]
      },
      kind: :read,
      function: fn args ->
        url = Map.fetch!(args, "url")
        method = Map.get(args, "method", "GET") |> String.downcase() |> String.to_atom()
        headers = Map.get(args, "headers", %{})
        body = Map.get(args, "body")

        with :ok <- validate_url(url, allowed_domains),
             {:ok, response} <- do_request(method, url, headers, body, timeout, max_body_size) do
          result = %{
            "status" => response.status,
            "body" => truncate_body(response.body, max_body_size),
            "headers" => format_headers(response.headers)
          }

          {:ok, Jason.encode!(result, pretty: true)}
        end
      end
    )
  end

  defp fetch_json_tool(allowed_domains, timeout, max_body_size) do
    Tool.new(
      name: "fetch_json",
      description:
        "Fetch a URL and parse the response as JSON. " <>
          "Returns the parsed JSON data. Useful for REST API calls.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" => "The URL to fetch (must be http:// or https://)"
          },
          "method" => %{
            "type" => "string",
            "enum" => ["GET", "POST", "PUT", "DELETE", "PATCH"],
            "description" => "HTTP method (default: GET)"
          },
          "headers" => %{
            "type" => "object",
            "description" => "Additional HTTP headers as key-value pairs"
          },
          "body" => %{
            "type" => "string",
            "description" => "Request body (for POST/PUT/PATCH)"
          }
        },
        "required" => ["url"]
      },
      kind: :read,
      function: fn args ->
        url = Map.fetch!(args, "url")
        method = Map.get(args, "method", "GET") |> String.downcase() |> String.to_atom()
        headers = Map.get(args, "headers", %{}) |> Map.put("accept", "application/json")
        body = Map.get(args, "body")

        with :ok <- validate_url(url, allowed_domains),
             {:ok, response} <- do_request(method, url, headers, body, timeout, max_body_size) do
          case Jason.decode(response.body) do
            {:ok, json} ->
              {:ok, Jason.encode!(%{"status" => response.status, "data" => json}, pretty: true)}

            {:error, _} ->
              {:error, "Response is not valid JSON (status #{response.status}): #{truncate_body(response.body, 500)}"}
          end
        end
      end
    )
  end

  # --- Helpers ---

  defp validate_url(url, allowed_domains) do
    with :ok <- validate_scheme(url),
         :ok <- validate_domain(url, allowed_domains) do
      AgentEx.NetworkPolicy.validate(url)
    end
  end

  defp validate_scheme(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] do
      :ok
    else
      {:error, "Only http:// and https:// URLs are allowed, got: #{uri.scheme}"}
    end
  end

  defp validate_domain(_url, nil), do: :ok

  defp validate_domain(url, allowed_domains) do
    uri = URI.parse(url)
    host = uri.host || ""

    if Enum.any?(allowed_domains, fn domain ->
         host == domain or String.ends_with?(host, "." <> domain)
       end) do
      :ok
    else
      {:error, "Domain '#{host}' not in allowed list: #{Enum.join(allowed_domains, ", ")}"}
    end
  end

  defp do_request(method, url, headers, body, timeout, _max_body_size) do
    header_list = Enum.map(headers, fn {k, v} -> {String.to_atom(k), v} end)

    req_opts = [
      method: method,
      url: url,
      headers: header_list,
      receive_timeout: timeout,
      connect_options: [timeout: timeout],
      redirect: true,
      max_redirects: 5,
      retry: false
    ]

    req_opts = if body, do: Keyword.put(req_opts, :body, body), else: req_opts

    case Req.request(req_opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "Connection failed: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp truncate_body(body, max_size) when is_binary(body) do
    if byte_size(body) > max_size do
      String.slice(body, 0, max_size) <> "\n... [truncated at #{max_size} bytes]"
    else
      body
    end
  end

  defp truncate_body(body, _max_size), do: inspect(body)

  defp format_headers(headers) do
    Enum.into(headers, %{}, fn {k, v} -> {to_string(k), List.wrap(v) |> Enum.join(", ")} end)
  end
end
