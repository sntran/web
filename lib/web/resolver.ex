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
  def resolve(input) when is_binary(input) do
    cond do
      String.starts_with?(input, "http://") or String.starts_with?(input, "https://") ->
        Web.Dispatcher.HTTP

      String.starts_with?(input, "tcp://") ->
        Web.Dispatcher.TCP

      # Support connection strings like remote:path/to/file (rclone-style prefix)
      String.contains?(input, ":") and not String.match?(input, ~r/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//) ->
        Web.Dispatcher.TCP

      true ->
        Web.Dispatcher.HTTP
    end
  end
end
