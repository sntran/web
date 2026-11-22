defmodule Web.Symbol do
  @moduledoc """
  The well-known symbols of ECMAScript that this library uses.

  In ECMAScript, a well-known symbol is the key of a function that the
  language calls: `Symbol.dispose` is the key of the function that releases
  a resource at the end of a `using` block. In Elixir, an atom is the key.

  ## Disposable resources

  `Web.using/2` releases a disposable value at the end of its block. These
  values are disposable:

    * `Web.MessagePort` and `Web.BroadcastChannel` - closes it;
    * `Web.Socket` - closes it;
    * `Web.ReadableStreamDefaultReader`, `Web.ReadableStreamBYOBReader`, and
      `Web.WritableStreamDefaultWriter` - releases the lock;
    * `Web.GovernorToken` - releases the token, as
      `GovernorToken.prototype[Symbol.dispose]()`;
    * `Port` - closes it.

  The Streams Standard does not specify the disposal of a reader and a
  writer at this time. The library follows the proposal for that Standard.
  """

  @type t :: :dispose | :async_dispose | :iterator | :async_iterator

  @doc "The symbol of the function that releases a resource."
  @spec dispose() :: :dispose
  def dispose, do: :dispose

  @doc """
  The symbol of the function that releases a resource and returns a
  `Web.Promise`.
  """
  @spec async_dispose() :: :async_dispose
  def async_dispose, do: :async_dispose

  @doc "The symbol of the function that returns an iterator."
  @spec iterator() :: :iterator
  def iterator, do: :iterator

  @doc "The symbol of the function that returns an async iterator."
  @spec async_iterator() :: :async_iterator
  def async_iterator, do: :async_iterator

  @doc false
  # Tells if a value is disposable: its type has an implementation of
  # `Web.Symbol.Protocol`.
  @spec disposable?(term()) :: boolean()
  def disposable?(value), do: Web.Symbol.Protocol.impl_for(value) != Web.Symbol.Protocol.Any

  # ---------------------------------------------------------------------------
  # The functions of the macro `Web.using/2`
  # ---------------------------------------------------------------------------

  @doc false
  # The check that ECMAScript does at the declaration: the value is `nil`,
  # or it is disposable.
  @spec check_disposable!(term()) :: :ok
  def check_disposable!(nil), do: :ok

  def check_disposable!(value) do
    if disposable?(value) do
      :ok
    else
      raise Web.TypeError, "The value is not disposable: #{inspect(value)}"
    end
  end

  @doc false
  # Runs the block of `Web.using/2`, then releases the resource. The rules
  # are those of ECMAScript:
  #
  #   * the resource is released also when the block throws;
  #   * a value that the block throws is thrown again after the disposal;
  #   * a value that the disposal throws is thrown. When the block threw
  #     too, the two values are in a `Web.SuppressedError`.
  @spec run_using(term(), (-> result)) :: result when result: term()
  def run_using(nil, block), do: block.()

  def run_using(resource, block) do
    outcome = capture(block)
    disposal = capture(fn -> dispose!(resource) end)

    case {outcome, disposal} do
      {{:ok, value}, {:ok, _result}} ->
        value

      {{:ok, _value}, {kind, reason, stacktrace}} ->
        :erlang.raise(kind, reason, stacktrace)

      {{kind, reason, stacktrace}, {:ok, _result}} ->
        :erlang.raise(kind, reason, stacktrace)

      {{_kind, suppressed, _stacktrace}, {_disposal_kind, error, stacktrace}} ->
        reraise %Web.SuppressedError{error: error, suppressed: suppressed}, stacktrace
    end
  end

  defp capture(fun) do
    {:ok, fun.()}
  catch
    kind, reason -> {kind, reason, __STACKTRACE__}
  end

  # Uses the function of `:dispose`. A resource that has only the function
  # of `:async_dispose` uses that one. A promise is awaited.
  defp dispose!(resource) do
    case Web.Symbol.Protocol.symbol(resource, :dispose, []) do
      :unsupported -> async_dispose!(resource)
      result -> settle(result)
    end
  end

  defp async_dispose!(resource) do
    case Web.Symbol.Protocol.symbol(resource, :async_dispose, []) do
      :unsupported -> raise Web.TypeError, "The value is not disposable: #{inspect(resource)}"
      result -> settle(result)
    end
  end

  defp settle(%Web.Promise{} = promise), do: Web.Promise.await(promise)
  defp settle(result), do: result
end

defprotocol Web.Symbol.Protocol do
  @moduledoc false

  # The functions of a value for the well-known symbols of `Web.Symbol`.
  # Only the library implements this protocol. An implementation returns
  # `:unsupported` for a symbol that the value does not have.

  @fallback_to_any true

  # Calls the function of the value for the symbol, with the arguments. For
  # `:dispose` and `:async_dispose`, the function releases the resource. It
  # can return a `Web.Promise`: `Web.using/2` awaits it. The function must
  # accept a resource that is released already.
  @spec symbol(term(), Web.Symbol.t(), list()) :: term()
  def symbol(resource, symbol_type, args)
end

defimpl Web.Symbol.Protocol, for: Any do
  def symbol(_resource, _symbol_type, _args), do: :unsupported
end

defimpl Web.Symbol.Protocol, for: Port do
  def symbol(port, symbol, _args) when symbol in [:dispose, :async_dispose] do
    Port.close(port)
    :ok
  rescue
    # The port is closed already, or a different process has it.
    ArgumentError -> :ok
  end

  def symbol(_port, _symbol, _args), do: :unsupported
end

defimpl Web.Symbol.Protocol, for: Web.BroadcastChannel do
  def symbol(channel, symbol, _args) when symbol in [:dispose, :async_dispose] do
    Web.BroadcastChannel.close(channel)
  end

  def symbol(_channel, _symbol, _args), do: :unsupported
end

defimpl Web.Symbol.Protocol, for: Web.MessagePort do
  def symbol(port, symbol, _args) when symbol in [:dispose, :async_dispose] do
    Web.MessagePort.close(port)
  end

  def symbol(_port, _symbol, _args), do: :unsupported
end

defimpl Web.Symbol.Protocol, for: Web.Socket do
  def symbol(socket, symbol, _args) when symbol in [:dispose, :async_dispose] do
    Web.Socket.close(socket)
  end

  def symbol(_socket, _symbol, _args), do: :unsupported
end

defimpl Web.Symbol.Protocol,
  for: [Web.ReadableStreamDefaultReader, Web.ReadableStreamBYOBReader] do
  def symbol(%module{} = reader, symbol, _args) when symbol in [:dispose, :async_dispose] do
    module.release_lock(reader)
    :ok
  end

  def symbol(_reader, _symbol, _args), do: :unsupported
end

defimpl Web.Symbol.Protocol, for: Web.WritableStreamDefaultWriter do
  def symbol(writer, symbol, _args) when symbol in [:dispose, :async_dispose] do
    Web.WritableStreamDefaultWriter.release_lock(writer)
    :ok
  end

  def symbol(_writer, _symbol, _args), do: :unsupported
end

defimpl Web.Symbol.Protocol, for: Web.GovernorToken do
  def symbol(token, symbol, _args) when symbol in [:dispose, :async_dispose] do
    Web.GovernorToken.release(token)
  end

  def symbol(_token, _symbol, _args), do: :unsupported
end
