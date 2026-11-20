defmodule Web.Internal.Address do
  @moduledoc false

  # The address of a host for `:gen_tcp`, `:ssl`, and Mint.
  #
  # `:gen_tcp.connect/4` looks up a host that is a charlist as a name, also
  # when the charlist is an IP address: `~c"127.0.0.1"` takes approximately
  # 300 µs, and the tuple `{127, 0, 0, 1}` takes 90 µs. Without the option
  # `:inet6`, it does not try an IPv6 address such as `~c"::1"`: the result
  # is `{:error, :nxdomain}`. A tuple of 8 numbers selects IPv6.
  #
  # Thus an IP address goes to the connect as a tuple, and a name stays a
  # charlist: `:gen_tcp` then tries each address of the name.

  @doc """
  The IP address of a host, or `:error` for a name. An IPv6 address can
  have the brackets of a URL, such as `"[::1]"`.
  """
  @spec ip(String.t()) :: {:ok, :inet.ip_address()} | :error
  def ip("[" <> rest) do
    case String.split(rest, "]") do
      [address, ""] -> ipv6(address)
      _other -> :error
    end
  end

  def ip(host) when is_binary(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  defp ipv6(address) do
    case :inet.parse_ipv6strict_address(String.to_charlist(address)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  @doc "The address for `:gen_tcp.connect/4` and `:ssl.connect/4`."
  @spec endpoint(String.t()) :: :inet.ip_address() | charlist()
  def endpoint(host) when is_binary(host) do
    case ip(host) do
      {:ok, address} -> address
      :error -> String.to_charlist(host)
    end
  end

  @doc """
  The address for `Mint.HTTP.connect/4`. Mint needs the option `:hostname`
  with a tuple: see `mint_options/2`.
  """
  @spec mint(String.t()) :: :inet.ip_address() | String.t()
  def mint(host) when is_binary(host) do
    case ip(host) do
      {:ok, address} -> address
      :error -> host
    end
  end

  @doc """
  The options of `Mint.HTTP.connect/4` for the host. Mint makes the header
  `Host` from the option `:hostname`, with the brackets of an IPv6 address.
  """
  @spec mint_options(String.t(), keyword()) :: keyword()
  def mint_options(host, options), do: Keyword.put(options, :hostname, hostname(host))

  @doc "The host with no brackets: `\"[::1]\"` is `\"::1\"`."
  @spec hostname(String.t()) :: String.t()
  def hostname("[" <> rest), do: String.trim_trailing(rest, "]")
  def hostname(host), do: host

  @doc "The text of a host and a port, with brackets for an IPv6 address."
  @spec format(String.t(), :inet.port_number()) :: String.t()
  def format(host, port) do
    if String.contains?(host, ":") and not String.starts_with?(host, "["),
      do: "[#{host}]:#{port}",
      else: "#{host}:#{port}"
  end
end
