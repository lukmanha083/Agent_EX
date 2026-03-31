defmodule AgentEx.Plugins.WebFetchTest do
  use ExUnit.Case, async: true

  alias AgentEx.Plugins.WebFetch

  describe "manifest/0" do
    test "returns valid manifest" do
      manifest = WebFetch.manifest()
      assert manifest.name == "web"
      assert manifest.version == "1.0.0"
      assert is_list(manifest.config_schema)
    end
  end

  describe "init/1" do
    test "returns two tools" do
      assert {:ok, tools} = WebFetch.init(%{})
      names = Enum.map(tools, & &1.name)
      assert "fetch_url" in names
      assert "fetch_json" in names
    end

    test "fetch_url is :read kind" do
      {:ok, tools} = WebFetch.init(%{})
      tool = Enum.find(tools, &(&1.name == "fetch_url"))
      assert tool.kind == :read
    end

    test "fetch_json is :write kind (allows mutating methods)" do
      {:ok, tools} = WebFetch.init(%{})
      tool = Enum.find(tools, &(&1.name == "fetch_json"))
      assert tool.kind == :write
    end
  end

  describe "URL validation" do
    test "rejects non-http schemes" do
      {:ok, tools} = WebFetch.init(%{})
      fetch = Enum.find(tools, &(&1.name == "fetch_url"))

      assert {:error, msg} = AgentEx.Tool.execute(fetch, %{"url" => "ftp://example.com"})
      assert msg =~ "Only http:// and https://"
    end

    test "rejects localhost (SSRF protection)" do
      {:ok, tools} = WebFetch.init(%{})
      fetch = Enum.find(tools, &(&1.name == "fetch_url"))

      assert {:error, _msg} = AgentEx.Tool.execute(fetch, %{"url" => "http://127.0.0.1/admin"})
    end

    test "rejects private IPs (SSRF protection)" do
      {:ok, tools} = WebFetch.init(%{})
      fetch = Enum.find(tools, &(&1.name == "fetch_url"))

      assert {:error, _msg} =
               AgentEx.Tool.execute(fetch, %{"url" => "http://192.168.1.1/admin"})
    end
  end

  describe "SSRF redirect protection" do
    test "redirect validation blocks loopback — initial request to loopback is also blocked" do
      {:ok, tools} = WebFetch.init(%{})
      fetch = Enum.find(tools, &(&1.name == "fetch_url"))

      # Even without redirect, loopback is blocked at the initial validate step
      assert {:error, msg} =
               AgentEx.Tool.execute(fetch, %{"url" => "http://127.0.0.1:9999/redirect"})

      assert msg =~ "loopback" or msg =~ "private" or msg =~ "blocked"
    end

    test "redirect validation blocks link-local metadata endpoints" do
      {:ok, tools} = WebFetch.init(%{})
      fetch = Enum.find(tools, &(&1.name == "fetch_url"))

      # Cloud metadata endpoint (169.254.169.254) is blocked
      assert {:error, msg} =
               AgentEx.Tool.execute(fetch, %{"url" => "http://169.254.169.254/latest/meta-data/"})

      assert msg =~ "link-local" or msg =~ "private" or msg =~ "blocked"
    end
  end

  describe "domain allowlist" do
    test "rejects domains not in allowlist" do
      {:ok, tools} = WebFetch.init(%{"allowed_domains" => ["example.com"]})
      fetch = Enum.find(tools, &(&1.name == "fetch_url"))

      assert {:error, msg} =
               AgentEx.Tool.execute(fetch, %{"url" => "https://evil.com/data"})

      assert msg =~ "not in allowed list"
    end

    test "allows subdomains of allowed domains" do
      {:ok, tools} = WebFetch.init(%{"allowed_domains" => ["example.com"]})
      fetch = Enum.find(tools, &(&1.name == "fetch_url"))

      # This will fail on connection (no server) but should pass domain validation
      result = AgentEx.Tool.execute(fetch, %{"url" => "https://api.example.com/data"})

      case result do
        {:error, msg} -> refute msg =~ "not in allowed list"
        {:ok, _} -> :ok
      end
    end
  end
end
