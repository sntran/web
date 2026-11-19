defmodule Web.Internal.Ascii do
  @moduledoc false

  # Checks and changes of ASCII text, with binary pattern matching.
  #
  # The parsers of URLs, headers, and MIME types use these functions in the
  # place of regular expressions. On Erlang/OTP 28 and later, each run of a
  # compiled regular expression imports the pattern again, and that is the
  # largest cost of a short input. A byte that is not ASCII is never a
  # member of an ASCII set, thus these functions examine bytes, not code
  # points.

  defguardp digit?(char) when char in ?0..?9
  defguardp upper?(char) when char in ?A..?Z
  defguardp hex?(char) when char in ?0..?9 or char in ?A..?F or char in ?a..?f

  # A character of a token of HTTP (RFC 9110, section 5.6.2).
  defguardp tchar?(char)
            when char in ?0..?9 or char in ?A..?Z or char in ?a..?z or
                   char in [?!, ?#, ?$, ?%, ?&, ?', ?*, ?+, ?-, ?., ?^, ?_, ?`, ?|, ?~]

  @doc "Tells if `value` has one or more bytes, and each one is a digit."
  @spec digits?(binary()) :: boolean()
  def digits?(<<char, rest::binary>>) when digit?(char), do: all_digits?(rest)
  def digits?(_value), do: false

  defp all_digits?(<<char, rest::binary>>) when digit?(char), do: all_digits?(rest)
  defp all_digits?(<<>>), do: true
  defp all_digits?(_value), do: false

  @doc "Tells if `value` has one or more bytes, and each one is an octal digit."
  @spec octal_digits?(binary()) :: boolean()
  def octal_digits?(<<char, rest::binary>>) when char in ?0..?7, do: all_octal?(rest)
  def octal_digits?(_value), do: false

  defp all_octal?(<<char, rest::binary>>) when char in ?0..?7, do: all_octal?(rest)
  defp all_octal?(<<>>), do: true
  defp all_octal?(_value), do: false

  @doc "Tells if each byte of `value` is a hexadecimal digit. An empty value is true."
  @spec hex_digits?(binary()) :: boolean()
  def hex_digits?(<<char, rest::binary>>) when hex?(char), do: hex_digits?(rest)
  def hex_digits?(<<>>), do: true
  def hex_digits?(_value), do: false

  @doc """
  Returns the digits at the start of `value`, and the rest. The digits can
  be empty.
  """
  @spec split_digits(binary()) :: {binary(), binary()}
  def split_digits(value) do
    count = count_digits(value, 0)
    {binary_part(value, 0, count), binary_part(value, count, byte_size(value) - count)}
  end

  defp count_digits(<<char, rest::binary>>, count) when digit?(char),
    do: count_digits(rest, count + 1)

  defp count_digits(_value, count), do: count

  @doc "Tells if `value` is a token of HTTP: one or more token characters."
  @spec token?(term()) :: boolean()
  def token?(<<char, rest::binary>>) when tchar?(char), do: all_tchar?(rest)
  def token?(_value), do: false

  defp all_tchar?(<<char, rest::binary>>) when tchar?(char), do: all_tchar?(rest)
  defp all_tchar?(<<>>), do: true
  defp all_tchar?(_value), do: false

  @doc """
  Returns the lower-case form of a token of HTTP, or `:error` when `value`
  is not a token. A token with no upper-case letter is returned with no
  copy.
  """
  @spec downcase_token(binary()) :: binary() | :error
  def downcase_token(value), do: downcase_token(value, value, false)

  defp downcase_token(<<char, rest::binary>>, value, _upper?) when upper?(char),
    do: downcase_token(rest, value, true)

  defp downcase_token(<<char, rest::binary>>, value, upper?) when tchar?(char),
    do: downcase_token(rest, value, upper?)

  defp downcase_token(<<>>, "", _upper?), do: :error
  defp downcase_token(<<>>, value, false), do: value
  defp downcase_token(<<>>, value, true), do: String.downcase(value, :ascii)
  defp downcase_token(_rest, _value, _upper?), do: :error

  @doc """
  Changes the ASCII upper-case letters of `value` to lower case. Each other
  byte stays. A value with no upper-case letter is returned with no copy.
  """
  @spec downcase(binary()) :: binary()
  def downcase(value) when is_binary(value) do
    if has_upper?(value), do: String.downcase(value, :ascii), else: value
  end

  defp has_upper?(<<char, _rest::binary>>) when upper?(char), do: true
  defp has_upper?(<<_char, rest::binary>>), do: has_upper?(rest)
  defp has_upper?(<<>>), do: false

  @doc "Tells if each byte of `value` is below 0x80."
  @spec ascii?(binary()) :: boolean()
  def ascii?(<<char, rest::binary>>) when char < 0x80, do: ascii?(rest)
  def ascii?(<<>>), do: true
  def ascii?(_value), do: false

  @doc "Removes the bytes at the start of `value` that `trim?` accepts."
  @spec trim_leading(binary(), (byte() -> boolean())) :: binary()
  def trim_leading(<<char, rest::binary>> = value, trim?) do
    if trim?.(char), do: trim_leading(rest, trim?), else: value
  end

  def trim_leading(<<>>, _trim?), do: <<>>

  @doc "Removes the bytes at the end of `value` that `trim?` accepts."
  @spec trim_trailing(binary(), (byte() -> boolean())) :: binary()
  def trim_trailing(value, trim?), do: trim_trailing(value, byte_size(value), trim?)

  defp trim_trailing(value, 0, _trim?), do: binary_part(value, 0, 0)

  defp trim_trailing(value, size, trim?) do
    if trim?.(:binary.at(value, size - 1)),
      do: trim_trailing(value, size - 1, trim?),
      else: binary_part(value, 0, size)
  end
end
