defmodule AgentEx.NetworkPolicy do
  @moduledoc """
  SSRF protection — validates URLs before server-side HTTP requests.

  Blocks requests to:
  - Loopback (127.0.0.0/8, ::1)
  - RFC1918 private networks (10/8, 172.16/12, 192.168/16)
  - Link-local / cloud metadata (169.254/16, fe80::/10)
  - Fly.io private network (fdaa::/16, *.internal hostnames)
  - IPv6-mapped IPv4 (::ffff:127.0.0.1 etc.)

  Used by HttpTool.build_function and ToolsLive.run_http_test to prevent
  user-defined HTTP tools from reaching internal services.
  """

  import Bitwise

  @doc """
  Validate that a URL points to an external host.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(String.t()) :: :ok | {:error, String.t()}
  def validate(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: nil} ->
        {:error, "URL has no host"}

      %URI{scheme: scheme} when scheme not in ["http", "https"] ->
        {:error, "unsupported scheme: #{scheme || "none"} (only http/https allowed)"}

      %URI{host: host} ->
        check_host(host)
    end
  end

  def validate(_), do: {:error, "invalid URL"}

  @doc "Same as validate/1 but raises on blocked URLs."
  @spec validate!(String.t()) :: :ok
  def validate!(url) do
    case validate(url) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "Blocked URL: #{reason}"
    end
  end

  # --- Host checks ---

  defp check_host(host) do
    # Block *.internal (Fly.io private DNS)
    if String.ends_with?(host, ".internal") do
      {:error, "requests to .internal hosts are blocked (private network)"}
    else
      resolve_and_check(host)
    end
  end

  defp resolve_and_check(host) do
    charlist = String.to_charlist(host)
    ipv4s = resolve_addrs(charlist, :inet)
    ipv6s = resolve_addrs(charlist, :inet6)

    if ipv4s == [] and ipv6s == [] do
      {:error, "cannot resolve host: #{host}"}
    else
      check_all_ips(ipv4s, ipv6s)
    end
  end

  defp resolve_addrs(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, addrs} -> addrs
      {:error, _} -> []
    end
  end

  defp check_all_ips(ipv4s, ipv6s) do
    results =
      Enum.map(ipv4s, &check_ip/1) ++ Enum.map(ipv6s, &check_ip6/1)

    Enum.find(results, :ok, fn
      {:error, _} -> true
      :ok -> false
    end)
  end

  # IPv4 checks
  defp check_ip({127, _, _, _}), do: blocked("loopback (127.0.0.0/8)")
  defp check_ip({10, _, _, _}), do: blocked("private network (10.0.0.0/8)")

  defp check_ip({172, b, _, _}) when b >= 16 and b <= 31,
    do: blocked("private network (172.16.0.0/12)")

  defp check_ip({192, 168, _, _}), do: blocked("private network (192.168.0.0/16)")
  defp check_ip({169, 254, _, _}), do: blocked("link-local / metadata (169.254.0.0/16)")
  defp check_ip({0, 0, 0, 0}), do: blocked("unspecified address (0.0.0.0)")

  defp check_ip({100, b, _, _}) when b >= 64 and b <= 127,
    do: blocked("CGN shared address (100.64.0.0/10)")

  defp check_ip({192, 0, 0, _}), do: blocked("IETF protocol (192.0.0.0/24)")
  defp check_ip({192, 0, 2, _}), do: blocked("documentation (192.0.2.0/24)")
  defp check_ip({198, 51, 100, _}), do: blocked("documentation (198.51.100.0/24)")
  defp check_ip({203, 0, 113, _}), do: blocked("documentation (203.0.113.0/24)")

  defp check_ip({198, b, _, _}) when b in [18, 19],
    do: blocked("benchmarking (198.18.0.0/15)")

  defp check_ip(_), do: :ok

  # IPv6 checks
  defp check_ip6({0, 0, 0, 0, 0, 0, 0, 1}), do: blocked("loopback (::1)")
  defp check_ip6({0, 0, 0, 0, 0, 0, 0, 0}), do: blocked("unspecified address (::)")
  # fe80::/10 link-local
  defp check_ip6({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF,
    do: blocked("link-local (fe80::/10)")

  # fdaa::/16 Fly.io private network
  defp check_ip6({0xFDAA, _, _, _, _, _, _, _}), do: blocked("Fly.io private network (fdaa::/16)")
  # fc00::/7 unique local (ULA) — covers fd00::/8 and fc00::/8
  defp check_ip6({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF,
    do: blocked("unique local address (fc00::/7)")

  # ::ffff:0:0/96 IPv4-mapped — check the embedded IPv4
  defp check_ip6({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    ipv4 = {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}
    check_ip(ipv4)
  end

  defp check_ip6(_), do: :ok

  defp blocked(reason), do: {:error, "requests to #{reason} are blocked"}
end
