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
  @max_redirects 5
  @valid_methods ~w[get post put delete patch head]a

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
            "enum" => ["GET", "HEAD"],
            "description" =>
              "HTTP method (default: GET). Only safe methods allowed for read tool."
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
        headers = Map.get(args, "headers", %{})
        body = Map.get(args, "body")

        with {:ok, method} <- validate_method(Map.get(args, "method", "GET")),
             :ok <- validate_url(url, allowed_domains),
             {:ok, response} <-
               do_request(method, url, headers, body, timeout, max_body_size, allowed_domains) do
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
      kind: :write,
      function: fn args ->
        url = Map.fetch!(args, "url")
        headers = Map.get(args, "headers", %{}) |> Map.put("accept", "application/json")
        body = Map.get(args, "body")

        with {:ok, method} <- validate_method(Map.get(args, "method", "GET")),
             :ok <- validate_url(url, allowed_domains),
             {:ok, response} <-
               do_request(method, url, headers, body, timeout, max_body_size, allowed_domains) do
          case Jason.decode(response.body) do
            {:ok, json} ->
              {:ok, Jason.encode!(%{"status" => response.status, "data" => json}, pretty: true)}

            {:error, _} ->
              {:error,
               "Response is not valid JSON (status #{response.status}): #{truncate_body(response.body, 500)}"}
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

  defp validate_method(method_str) do
    method = String.downcase(method_str)

    if String.to_existing_atom(method) in @valid_methods do
      {:ok, String.to_existing_atom(method)}
    else
      {:error, "Invalid HTTP method: #{method_str}. Allowed: #{Enum.join(@valid_methods, ", ")}"}
    end
  rescue
    ArgumentError ->
      {:error, "Invalid HTTP method: #{method_str}. Allowed: #{Enum.join(@valid_methods, ", ")}"}
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

  defp do_request(method, url, headers, body, timeout, max_body_size, allowed_domains) do
    header_list = Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)

    req_opts = [
      method: method,
      url: url,
      headers: header_list,
      receive_timeout: timeout,
      connect_options: [timeout: timeout],
      redirect: false,
      retry: false,
      max_body_size: max_body_size,
      allowed_domains: allowed_domains
    ]

    req_opts = if body, do: Keyword.put(req_opts, :body, body), else: req_opts

    do_request_with_redirects(req_opts, @max_redirects)
  end

  defp do_request_with_redirects(_req_opts, remaining) when remaining < 0 do
    {:error, "Too many redirects"}
  end

  defp do_request_with_redirects(req_opts, remaining) do
    case Req.request(req_opts) do
      {:ok, %{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        follow_redirect(response, req_opts, remaining)

      {:ok, response} ->
        {:ok, response}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "Connection failed: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp follow_redirect(response, req_opts, remaining) do
    case get_redirect_location(response) do
      nil ->
        {:ok, response}

      location ->
        redirect_url = resolve_redirect_url(Keyword.fetch!(req_opts, :url), location)
        allowed_domains = Keyword.get(req_opts, :allowed_domains)

        with :ok <- AgentEx.NetworkPolicy.validate(redirect_url),
             :ok <- validate_domain(redirect_url, allowed_domains) do
          new_opts = Keyword.put(req_opts, :url, redirect_url)
          do_request_with_redirects(new_opts, remaining - 1)
        else
          {:error, reason} ->
            {:error, "Redirect to #{redirect_url} blocked: #{reason}"}
        end
    end
  end

  defp get_redirect_location(%{headers: headers}) do
    Enum.find_value(headers, fn
      {"location", value} -> value
      {key, value} when is_binary(key) -> if String.downcase(key) == "location", do: value
      _ -> nil
    end)
  end

  defp resolve_redirect_url(base_url, location) do
    case URI.parse(location) do
      %{scheme: nil} -> URI.merge(base_url, location) |> to_string()
      _ -> location
    end
  end

  defp truncate_body(body, max_size) when is_binary(body) do
    if byte_size(body) > max_size do
      truncated = binary_part(body, 0, max_size)

      # Ensure valid UTF-8 by trimming broken trailing bytes
      truncated =
        case :unicode.characters_to_binary(truncated) do
          {:incomplete, valid, _} -> valid
          {:error, valid, _} -> valid
          valid when is_binary(valid) -> valid
        end

      truncated <> "\n... [truncated at #{max_size} bytes]"
    else
      body
    end
  end

  defp truncate_body(body, _max_size), do: inspect(body)

  defp format_headers(headers) do
    Enum.into(headers, %{}, fn {k, v} -> {to_string(k), List.wrap(v) |> Enum.join(", ")} end)
  end
end
