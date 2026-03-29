defmodule Web.Dispatcher do
  @moduledoc """
  Behaviour for generic request dispatching.
  """

  @callback fetch(Web.Request.t()) :: {:ok, Web.Response.t()} | {:error, any()}
end
