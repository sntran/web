defmodule Web.DSL do
  @moduledoc """
  Defines macros for the Web DSL.
  """

  @doc """
  DSL helper to create new Web objects with a constructor-style syntax.

  ## Examples

      iex> use Web
      iex> url = new URL, "https://example.com"
      iex> url.hostname
      "example.com"

      iex> use Web
      iex> req = new Request, "http://api.internal"
      iex> req.url.hostname
      "api.internal"
  """
  defmacro new(module, source) do
    quote do
      unquote(module).new(unquote(source))
    end
  end
end
