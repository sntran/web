defmodule Web.Dispatcher do
  @moduledoc false

  # The behaviour of a dispatcher of `Web.fetch/2`: the steps of a fetch for
  # one group of URL schemes. See `Web.Resolver`. The behaviour is internal:
  # the Fetch Standard has no such extension point.

  @callback fetch(Web.Request.t()) :: {:ok, Web.Response.t()} | {:error, any()}
end
