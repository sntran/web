defmodule Web.Resolver do
  @moduledoc """
  Parses input strings and resolves the correct Dispatcher for a given URL scheme.
  Matches the rclone-style resolver requirement.
  """

  @doc """
  Resolves a given URL or input string to a specific Dispatcher.

  ## Examples
      iex> Web.Resolver.resolve("http://example.com")
      Web.Dispatcher.HTTP

      iex> Web.Resolver.resolve("https://example.com")
      Web.Dispatcher.HTTP

      iex> Web.Resolver.resolve("tcp://localhost:8080")
      Web.Dispatcher.TCP

      iex> Web.Resolver.resolve("remote:path/to/file")
      Web.Dispatcher.TCP

      iex> Web.Resolver.resolve("bare-string")
      Web.Dispatcher.HTTP
  """
  def resolve(%Web.URL{} = url) do
    protocol = Web.URL.protocol(url)

    cond do
      protocol in ["http:", "https:"] ->
        Web.Dispatcher.HTTP

      protocol == "tcp:" ->
        Web.Dispatcher.TCP

      Web.URL.rclone?(url) ->
        Web.Dispatcher.TCP

      true ->
        Web.Dispatcher.HTTP
    end
  end

  def resolve(input) when is_binary(input) do
    if remote_syntax?(input) do
      Web.Dispatcher.TCP
    else
      resolve_string_input(input)
    end
  end

  defp resolve_string_input(input) do
    input
    |> Web.URL.new()
    |> resolve()
  rescue
    ArgumentError -> Web.Dispatcher.HTTP
  end

  defp remote_syntax?(input) do
    String.match?(input, ~r/^[A-Za-z0-9][A-Za-z0-9+.-]*:(?!\/\/).*$/)
  end
end
