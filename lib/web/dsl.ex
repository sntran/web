defmodule Web.DSL do
  @moduledoc false

  # The macro `new/2` of `use Web`: `new URL, "https://example.com"` is
  # `Web.URL.new("https://example.com")`. No Standard has it.

  @doc false
  defmacro new(module, source) do
    quote do
      unquote(module).new(unquote(source))
    end
  end
end
