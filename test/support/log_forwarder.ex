defmodule Web.TestSupport.LogForwarder do
  @moduledoc false

  # A handler of `:logger` that sends the messages of `Web.Console` to a
  # test process, as `{:console, level, text, metadata}`.
  #
  # With `attach/1`, the test gets only the messages of its own process,
  # thus the tests can run at the same time. With `attach/2` and the option
  # `all: true`, it gets the messages of each process that has the key
  # `:console_test` with the pid of the test in its logger metadata.

  def attach(pid, opts \\ []) do
    id = :"console_forwarder_#{System.unique_integer([:positive])}"
    config = %{pid: pid, all: Keyword.get(opts, :all, false)}
    :ok = :logger.add_handler(id, __MODULE__, %{config: config, level: :all})
    id
  end

  def detach(id), do: :logger.remove_handler(id)

  # The callback of the handler.
  def log(%{level: level, msg: msg, meta: %{console: true} = meta}, %{config: config}) do
    if meta[:pid] == config.pid or (config.all and meta[:console_test] == config.pid) do
      send(config.pid, {:console, level, text(msg), meta})
    end

    :ok
  end

  def log(_event, _config), do: :ok

  defp text({:string, chardata}), do: IO.chardata_to_string(chardata)
end
