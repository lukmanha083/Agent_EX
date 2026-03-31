defmodule AgentEx.HttpTool do
  @moduledoc """
  HTTP API tool definition — user-defined REST tools like n8n HTTP Request nodes.

  Stores the HTTP method, URL template, headers, parameters, and response
  extraction config. `to_tool/1` converts to a runtime `AgentEx.Tool` with
  a `Req`-based closure.

  URL templates use `{{param}}` interpolation for safe variable substitution.
  """

  alias AgentEx.Tool

  @enforce_keys [:id, :user_id, :project_id, :name, :method, :url_template]
  defstruct [
    :id,
    :user_id,
    :project_id,
    :name,
    :description,
    :method,
    :url_template,
    :response_type,
    :response_path,
    :inserted_at,
    :updated_at,
    kind: :read,
    headers: %{},
    parameters: []
  ]

  @type param :: %{
          name: String.t(),
          type: String.t(),
          description: String.t(),
          required: boolean()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          user_id: integer(),
          project_id: integer(),
          name: String.t(),
          description: String.t() | nil,
          kind: :read | :write,
          method: String.t(),
          url_template: String.t(),
          headers: map(),
          parameters: [param()],
          response_type: String.t() | nil,
          response_path: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @updatable_fields [
    :name,
    :description,
    :kind,
    :method,
    :url_template,
    :headers,
    :parameters,
    :response_type,
    :response_path
  ]

  @doc "Create a new HTTP tool config with generated ID and timestamps."
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    merged =
      attrs
      |> Map.put_new(:id, generate_id())
      |> Map.put_new(:kind, :read)
      |> Map.put_new(:headers, %{})
      |> Map.put_new(:parameters, [])
      |> Map.put_new(:inserted_at, now)
      |> Map.put_new(:updated_at, now)

    struct!(__MODULE__, merged)
  end

  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  @doc "Update an existing HTTP tool config."
  def update(%__MODULE__{} = config, attrs) when is_map(attrs) do
    updates = Map.take(attrs, @updatable_fields) |> Map.put(:updated_at, DateTime.utc_now())
    struct(config, updates)
  end

  @doc "Convert to a runtime `AgentEx.Tool` with a Req-based execution function."
  def to_tool(%__MODULE__{} = config) do
    Tool.new(
      name: config.name,
      description: config.description || "HTTP #{config.method} tool",
      kind: config.kind,
      parameters: build_json_schema(config.parameters),
      function: build_function(config)
    )
  end

  # --- Private ---

  defp build_function(config) do
    fn args ->
      url = interpolate(config.url_template, args)

      case AgentEx.NetworkPolicy.validate(url) do
        {:error, reason} -> {:error, "SSRF blocked: #{reason}"}
        :ok -> execute_request(config, args, url)
      end
    end
  end

  defp execute_request(config, args, url) do
    headers = interpolate_headers(config.headers, args)
    method = parse_method(config.method)

    url_params = extract_template_params(config.url_template)
    header_params = extract_header_params(config.headers)
    body_args = Map.drop(args, url_params ++ header_params)

    req_opts = [
      method: method,
      url: url,
      headers: headers,
      receive_timeout: 10_000,
      redirect: false
    ]

    req_opts =
      if method in [:post, :put, :patch] do
        Keyword.put(req_opts, :json, body_args)
      else
        req_opts
      end

    case Req.request(req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, extract_by_type(body, config.response_type, config.response_path)}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, exception} ->
        {:error, inspect(exception)}
    end
  end

  defp build_json_schema(parameters) when is_list(parameters) do
    properties = Map.new(parameters, &param_to_property/1)
    required = Enum.flat_map(parameters, &param_if_required/1)

    %{"type" => "object", "properties" => properties, "required" => required}
  end

  defp build_json_schema(_), do: %{"type" => "object", "properties" => %{}, "required" => []}

  defp param_to_property(param) do
    name = param[:name] || param["name"]
    type = param[:type] || param["type"] || "string"
    desc = param[:description] || param["description"]

    prop = %{"type" => type}
    prop = if desc in [nil, ""], do: prop, else: Map.put(prop, "description", desc)

    {name, prop}
  end

  defp param_if_required(param) do
    if param[:required] == true or param["required"] == true,
      do: [param[:name] || param["name"]],
      else: []
  end

  @doc false
  def interpolate(template, args) when is_binary(template) and is_map(args) do
    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn _match, key ->
      case Map.get(args, key) do
        nil -> "{{#{key}}}"
        val -> to_string(val)
      end
    end)
  end

  defp interpolate_headers(headers, args) when is_map(headers) do
    Map.new(headers, fn {k, v} -> {k, interpolate(v, args)} end)
  end

  defp interpolate_headers(_, _args), do: %{}

  @method_map %{
    "get" => :get,
    "post" => :post,
    "put" => :put,
    "patch" => :patch,
    "delete" => :delete,
    "head" => :head,
    "options" => :options
  }

  defp parse_method(method) when is_binary(method) do
    Map.get(@method_map, String.downcase(method), :get)
  end

  defp parse_method(_), do: :get

  defp extract_template_params(template) when is_binary(template) do
    Regex.scan(~r/\{\{(\w+)\}\}/, template) |> Enum.map(fn [_, key] -> key end)
  end

  defp extract_template_params(_), do: []

  defp extract_header_params(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {_k, v} -> extract_template_params(v) end)
  end

  defp extract_header_params(_), do: []

  defp extract_by_type(body, "raw_text", _path), do: format_body(body)
  defp extract_by_type(body, _type, path), do: extract_response(body, path)

  defp extract_response(body, nil), do: format_body(body)
  defp extract_response(body, ""), do: format_body(body)

  defp extract_response(body, path) when is_binary(path) and is_map(body) do
    keys = String.split(path, ".")

    case get_nested(body, keys) do
      nil -> format_body(body)
      value -> format_body(value)
    end
  end

  defp extract_response(body, _path), do: format_body(body)

  defp get_nested(value, []), do: value
  defp get_nested(map, [key | rest]) when is_map(map), do: get_nested(Map.get(map, key), rest)
  defp get_nested(_, _), do: nil

  defp format_body(body) when is_binary(body), do: body
  defp format_body(body), do: Jason.encode!(body)

  defp generate_id do
    "http-tool-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
  end
end
