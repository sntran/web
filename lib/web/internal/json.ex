defmodule Web.Internal.JSON do
  @moduledoc false

  # `JSON.parse` and `JSON.stringify` of ECMAScript, with the JSON modules
  # of Erlang/OTP and Elixir. They need no dependency, and the decoder is
  # approximately 30 % faster than Jason.
  #
  # The differences with ECMAScript that stay:
  #
  #   * A number that is too large for a float, such as `1e400`, is an
  #     error. ECMAScript gives `Infinity`. An integer with more than 310
  #     digits is also an error.
  #   * `-0` is the integer 0. ECMAScript gives the number -0.
  #   * A `\u` escape of a lone surrogate, such as `"\uD800"`, is an error.
  #     ECMAScript keeps the code unit, which a UTF-8 binary cannot have.
  #   * An integer stays an integer, and a number with a fraction or an
  #     exponent is a float: `1.0` is the float 1.0. ECMAScript has one
  #     number type.

  @doc """
  Decodes JSON text, as `JSON.parse` of ECMAScript. Returns `{:ok, value}`,
  or `{:error, %JSON.DecodeError{}}`.

  An object with the same key two times keeps the last value, as in
  ECMAScript. `null` is `nil`, and the keys are strings.

  With the option `reserve_heap: true`, the process gets a large heap for
  a large text: see `reserve_heap/1`. Give it only in a process that stops
  after the parse, such as the process of a promise.
  """
  @spec parse(binary(), keyword()) :: {:ok, term()} | {:error, JSON.DecodeError.t()}
  def parse(text, opts \\ []) when is_binary(text) do
    if Keyword.get(opts, :reserve_heap, false), do: reserve_heap(text)

    case JSON.decode(text, :ok, object_finish: &object_finish/2) do
      {value, :ok, rest} ->
        if blank?(rest), do: {:ok, value}, else: {:error, decode_error(text)}

      {:error, _reason} ->
        {:error, decode_error(text)}
    end
  end

  # The value of a large text needs a large heap. A heap that grows step by
  # step needs many garbage collections, which take more time than the
  # parse. Thus the process gets a heap of approximately the size of the
  # value at the start: 4 bytes of heap for each byte of text. The setting
  # stays for the life of the process.
  @large_text 65_536

  defp reserve_heap(text) when byte_size(text) > @large_text do
    Process.flag(:min_heap_size, div(byte_size(text), 2))
  end

  defp reserve_heap(_text), do: :ok

  # The decoder gives the pairs of an object from the last to the first. A
  # map from that list keeps the first value of a key, thus the list goes in
  # the sequence of the text first.
  defp object_finish(pairs, previous), do: {:maps.from_list(:lists.reverse(pairs)), previous}

  # The space that JSON permits after a value.
  defp blank?(<<char, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r], do: blank?(rest)
  defp blank?(rest), do: rest == ""

  # The exception of the decoder of Elixir has the message and the offset of
  # the error. A text that the decoder above refused is refused again here.
  defp decode_error(text) do
    JSON.decode!(text)
  rescue
    error in JSON.DecodeError -> error
  end

  @doc """
  Encodes a value as JSON text, as `JSON.stringify` of ECMAScript. Raises
  for a value that has no JSON form: a pid, a tuple, a struct with no
  implementation of `JSON.Encoder`, or a binary that is not valid UTF-8.
  """
  @spec stringify!(term()) :: binary()
  def stringify!(value), do: JSON.encode!(value)
end
