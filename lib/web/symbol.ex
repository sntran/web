defmodule Web.Symbol do
  @moduledoc """
  TC39-style well-known symbols used by the `Web` runtime.
  """

  @type t :: :dispose | :async_dispose | :iterator

  @spec dispose() :: :dispose
  def dispose, do: :dispose

  @spec async_dispose() :: :async_dispose
  def async_dispose, do: :async_dispose

  @spec iterator() :: :iterator
  def iterator, do: :iterator
end

defprotocol Web.Symbol.Protocol do
  @fallback_to_any true

  @spec symbol(term(), Web.Symbol.t(), list()) :: term()
  def symbol(resource, symbol_type, args)
end

defimpl Web.Symbol.Protocol, for: Any do
  def symbol(_resource, _symbol_type, _args), do: :unsupported
end

defimpl Web.Symbol.Protocol, for: Port do
  def symbol(port, :dispose, _args) do
    if Port.info(port) do
      Port.close(port)
    end

    :ok
  end

  def symbol(port, :async_dispose, args), do: symbol(port, :dispose, args)
  def symbol(_port, :iterator, _args), do: :unsupported
end

defimpl Web.Symbol.Protocol, for: Web.BroadcastChannel do
  def symbol(channel, :dispose, _args) do
    Web.BroadcastChannel.close(channel)
  end

  def symbol(channel, :async_dispose, args), do: symbol(channel, :dispose, args)
  def symbol(_channel, :iterator, _args), do: :unsupported
end
