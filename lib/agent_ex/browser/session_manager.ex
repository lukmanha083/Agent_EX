defmodule AgentEx.Browser.SessionManager do
  @moduledoc """
  Manages headless browser sessions for agent automation.

  Each session wraps a Wallaby browser process with:
  - Isolated session per agent task
  - Automatic cleanup on timeout
  - Screenshot capture after each action
  - Configurable viewport size
  """

  use GenServer

  require Logger

  @default_timeout 300_000
  @default_viewport %{width: 1280, height: 900}

  defstruct [:session, :owner, :started_at, screenshots: []]

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Start a new browser session. Returns {:ok, pid} or {:error, reason}."
  def start_session(manager) do
    GenServer.call(manager, :start_session, @default_timeout)
  end

  @doc "Navigate to a URL. Returns {:ok, %{title, url, screenshot}} or {:error, reason}."
  def navigate(manager, url) do
    GenServer.call(manager, {:navigate, url}, @default_timeout)
  end

  @doc "Click an element by CSS selector."
  def click(manager, selector) do
    GenServer.call(manager, {:click, selector}, @default_timeout)
  end

  @doc "Type text into an element by CSS selector."
  def type(manager, selector, text) do
    GenServer.call(manager, {:type, selector, text}, @default_timeout)
  end

  @doc "Take a screenshot. Returns {:ok, base64_png}."
  def screenshot(manager) do
    GenServer.call(manager, :screenshot, @default_timeout)
  end

  @doc "Extract text content from an element by CSS selector."
  def extract(manager, selector) do
    GenServer.call(manager, {:extract, selector}, @default_timeout)
  end

  @doc "Select a dropdown option by CSS selector and value."
  def select(manager, selector, value) do
    GenServer.call(manager, {:select, selector, value}, @default_timeout)
  end

  @doc "Wait for an element to appear."
  def wait_for(manager, selector, timeout \\ 10_000) do
    GenServer.call(manager, {:wait_for, selector, timeout}, @default_timeout)
  end

  @doc "Execute JavaScript in the browser."
  def execute_js(manager, script) do
    GenServer.call(manager, {:execute_js, script}, @default_timeout)
  end

  @doc "Stop the browser session."
  def stop_session(manager) do
    GenServer.stop(manager, :normal)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    viewport = Keyword.get(opts, :viewport, @default_viewport)
    owner = Keyword.get(opts, :owner)

    if owner, do: Process.monitor(owner)

    case start_wallaby_session(viewport) do
      {:ok, session} ->
        Logger.info("BrowserSession: started (#{viewport.width}x#{viewport.height})")

        {:ok,
         %__MODULE__{session: session, owner: owner, started_at: System.monotonic_time(:second)}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:start_session, _from, state) do
    {:reply, {:ok, self()}, state}
  end

  def handle_call({:navigate, url}, _from, state) do
    result =
      safe_browser_action(state.session, fn session ->
        session = Wallaby.Browser.visit(session, url)
        title = Wallaby.Browser.page_title(session)
        current_url = Wallaby.Browser.current_url(session)
        {session, {:ok, %{title: title, url: current_url}}}
      end)

    handle_action_result(result, state)
  end

  def handle_call({:click, selector}, _from, state) do
    result =
      safe_browser_action(state.session, fn session ->
        element = Wallaby.Browser.find(session, Wallaby.Query.css(selector))
        session = Wallaby.Browser.click(session, element)
        {session, {:ok, %{action: "clicked #{selector}"}}}
      end)

    handle_action_result(result, state)
  end

  def handle_call({:type, selector, text}, _from, state) do
    result =
      safe_browser_action(state.session, fn session ->
        session = Wallaby.Browser.fill_in(session, Wallaby.Query.css(selector), with: text)
        {session, {:ok, %{action: "typed into #{selector}"}}}
      end)

    handle_action_result(result, state)
  end

  def handle_call(:screenshot, _from, state) do
    result =
      safe_browser_action(state.session, fn session ->
        screenshot = take_screenshot_base64(session)
        {session, {:ok, screenshot}}
      end)

    handle_action_result(result, state)
  end

  def handle_call({:extract, selector}, _from, state) do
    result =
      safe_browser_action(state.session, fn session ->
        element = Wallaby.Browser.find(session, Wallaby.Query.css(selector))
        text = Wallaby.Element.text(element)
        {session, {:ok, text}}
      end)

    handle_action_result(result, state)
  end

  def handle_call({:select, selector, value}, _from, state) do
    result =
      safe_browser_action(state.session, fn session ->
        element = Wallaby.Browser.find(session, Wallaby.Query.css(selector))
        session = Wallaby.Browser.click(session, element)

        option =
          Wallaby.Browser.find(session, Wallaby.Query.option(value))

        session = Wallaby.Browser.click(session, option)
        {session, {:ok, %{action: "selected #{value} in #{selector}"}}}
      end)

    handle_action_result(result, state)
  end

  def handle_call({:wait_for, selector, timeout}, _from, state) do
    result =
      safe_browser_action(
        state.session,
        fn session ->
          case poll_for_element(session, selector, timeout) do
            :found -> {session, {:ok, "element #{selector} found"}}
            :timeout -> {session, {:error, :timeout}}
          end
        end,
        timeout
      )

    handle_action_result(result, state)
  end

  def handle_call({:execute_js, script}, _from, state) do
    result =
      safe_browser_action(state.session, fn session ->
        ref = make_ref()
        caller = self()

        Wallaby.Browser.execute_script(session, script, [], fn value ->
          send(caller, {ref, value})
        end)

        js_value =
          receive do
            {^ref, value} -> value
          after
            0 -> nil
          end

        {session, {:ok, js_value}}
      end)

    handle_action_result(result, state)
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Logger.info("BrowserSession: owner process died, shutting down")
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    end_browser_session(state.session)
  end

  defp end_browser_session(nil), do: :ok

  defp end_browser_session(session) do
    Wallaby.end_session(session)
    Logger.info("BrowserSession: ended")
  rescue
    _ -> :ok
  end

  # -- Private --

  @chrome_args ["--headless", "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"]

  defp start_wallaby_session(viewport) do
    args = @chrome_args ++ ["--window-size=#{viewport.width},#{viewport.height}"]
    capabilities = build_capabilities(args)
    {:ok, Wallaby.start_session(capabilities: capabilities)}
  rescue
    e -> {:error, {:browser_start_failed, Exception.message(e)}}
  end

  defp build_capabilities(args) do
    Wallaby.Chrome.default_capabilities()
    |> put_in([:chromeOptions, :args], args)
  end

  defp safe_browser_action(session, fun, timeout \\ 30_000) do
    task = Task.Supervisor.async_nolink(AgentEx.TaskSupervisor, fn -> fun.(session) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {session, {:error, reason}}
      nil -> {session, {:error, :timeout}}
    end
  rescue
    e ->
      Logger.warning("BrowserSession: action failed: #{Exception.message(e)}")
      {session, {:error, Exception.message(e)}}
  end

  defp handle_action_result({session, result}, state) do
    {:reply, result, %{state | session: session}}
  end

  defp poll_for_element(session, selector, timeout) do
    wait_until(timeout, fn ->
      case Wallaby.Browser.find(session, Wallaby.Query.css(selector, count: :any, minimum: 1)) do
        elements when is_list(elements) and elements != [] -> true
        _ -> false
      end
    end)
  end

  defp wait_until(timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> poll_once(fun, deadline) end)
    |> Enum.find(&(&1 != :continue))
  end

  defp poll_once(fun, deadline) do
    if fun.() do
      :found
    else
      Process.sleep(500)
      if System.monotonic_time(:millisecond) > deadline, do: :timeout, else: :continue
    end
  end

  defp take_screenshot_base64(session) do
    path = Wallaby.Browser.take_screenshot(session)
    read_and_encode_screenshot(path)
  rescue
    _ -> nil
  end

  defp read_and_encode_screenshot(path) do
    case File.read(path) do
      {:ok, data} ->
        File.rm(path)
        Base.encode64(data)

      {:error, _} ->
        nil
    end
  end
end
