defmodule Web.TestSupport.Disposable do
  @moduledoc false

  # A resource for the tests of `Web.using/2`. Its disposal sends a message
  # to the test process, then does what `mode` tells:
  #
  #   * `:ok` - returns `:ok`;
  #   * `:promise` - returns a promise;
  #   * `:async_only` - has only the function of `:async_dispose`;
  #   * `:raise`, `:throw`, `:exit` - fails;
  #   * `:rejected` - returns a promise that rejects;
  #   * `:unsupported` - has no function of disposal.

  defstruct [:name, :test, mode: :ok]

  def new(name, mode \\ :ok), do: %__MODULE__{name: name, test: self(), mode: mode}

  defimpl Web.Symbol.Protocol do
    def symbol(%{mode: :unsupported}, _symbol, _args), do: :unsupported
    def symbol(%{mode: :async_only}, :dispose, _args), do: :unsupported

    def symbol(resource, symbol, _args) when symbol in [:dispose, :async_dispose] do
      send(resource.test, {:disposed, resource.name, symbol})

      case resource.mode do
        :ok -> :ok
        :promise -> Web.Promise.resolve(:ok)
        :async_only -> Web.Promise.resolve(:ok)
        :raise -> raise "the disposal of #{resource.name} failed"
        :throw -> throw({:disposal, resource.name})
        :exit -> exit({:disposal, resource.name})
        :rejected -> Web.Promise.reject({:disposal, resource.name})
      end
    end

    def symbol(_resource, _symbol, _args), do: :unsupported
  end
end
