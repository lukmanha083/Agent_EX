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

    case :inet.getaddr(charlist, :inet) do
      {:ok, ip} ->
        check_ip(ip)

      {:error, _} ->
        # Try IPv6
        case :inet.getaddr(charlist, :inet6) do
          {:ok, ip6} -> check_ip6(ip6)
          {:error, _} -> {:error, "cannot resolve host: #{host}"}
        end
    end
  end

  # IPv4 checks
  defp check_ip({127, _, _, _}), do: blocked("loopback (127.0.0.0/8)")
  defp check_ip({10, _, _, _}), do: blocked("private network (10.0.0.0/8)")
  defp check_ip({172, b, _, _}) when b >= 16 and b <= 31, do: blocked("private network (172.16.0.0/12)")
  defp check_ip({192, 168, _, _}), do: blocked("private network (192.168.0.0/16)")
  defp check_ip({169, 254, _, _}), do: blocked("link-local / metadata (169.254.0.0/16)")
  defp check_ip({0, 0, 0, 0}), do: blocked("unspecified address (0.0.0.0)")
  defp check_ip(_), do: :ok

  # IPv6 checks
  defp check_ip6({0, 0, 0, 0, 0, 0, 0, 1}), do: blocked("loopback (::1)")
  defp check_ip6({0, 0, 0, 0, 0, 0, 0, 0}), do: blocked("unspecified address (::)")
  # fe80::/10 link-local
  defp check_ip6({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: blocked("link-local (fe80::/10)")
  # fdaa::/16 Fly.io private network
  defp check_ip6({0xFDAA, _, _, _, _, _, _, _}), do: blocked("Fly.io private network (fdaa::/16)")
  # fc00::/7 unique local (ULA) — covers fd00::/8 and fc00::/8
  defp check_ip6({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: blocked("unique local address (fc00::/7)")
  # ::ffff:0:0/96 IPv4-mapped — check the embedded IPv4
  defp check_ip6({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    ipv4 = {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}
    check_ip(ipv4)
  end

  defp check_ip6(_), do: :ok

  defp blocked(reason), do: {:error, "requests to #{reason} are blocked"}
end
