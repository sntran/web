defmodule Web.Resolver do
  @moduledoc """
  Parses input strings and resolves the correct Dispatcher for a given URL scheme.
  Matches the rclone-style resolver requirement.
  """

  defguardp alpha?(char) when char in ?A..?Z or char in ?a..?z
  defguardp digit?(char) when char in ?0..?9

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

      iex> Web.Resolver.resolve("blob:null/40a5fb5a-d56d-4a33-b4e2-0acf6a8e5f64")
      Web.Dispatcher.Blob
  """
  def resolve(%Web.URL{} = url) do
    protocol = Web.URL.protocol(url)

    cond do
      protocol in ["http:", "https:"] ->
        Web.Dispatcher.HTTP

      protocol == "tcp:" ->
        Web.Dispatcher.TCP

      protocol == "blob:" ->
        Web.Dispatcher.Blob

      Web.URL.rclone?(url) ->
        Web.Dispatcher.TCP

      true ->
        Web.Dispatcher.HTTP
    end
  end

  def resolve(input) when is_binary(input) do
    # A blob URL has the syntax of a remote name: its scheme decides.
    if remote_syntax?(input) and not blob_scheme?(input) do
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
    Web.TypeError -> Web.Dispatcher.HTTP
  end

  defp blob_scheme?(<<scheme::binary-size(5), _rest::binary>>),
    do: String.downcase(scheme) == "blob:"

  defp blob_scheme?(_input), do: false

  # A remote name: a letter or a digit, then letters, digits, "+", ".", and
  # "-", then ":" that is not followed by "//". The rest is one line: it has
  # no line feed, other than one at its end.
  defp remote_syntax?(<<char, rest::binary>>) when alpha?(char) or digit?(char),
    do: remote_name?(rest)

  defp remote_syntax?(_input), do: false

  defp remote_name?(<<char, rest::binary>>)
       when alpha?(char) or digit?(char) or char in [?+, ?., ?-],
       do: remote_name?(rest)

  defp remote_name?(<<?:, ?/, ?/, _rest::binary>>), do: false
  defp remote_name?(<<?:, rest::binary>>), do: one_line?(rest)
  defp remote_name?(_rest), do: false

  defp one_line?(rest) do
    case :binary.match(rest, "\n") do
      :nomatch -> true
      {index, 1} -> index == byte_size(rest) - 1
    end
  end
end
