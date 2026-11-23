defmodule Web.TestSupport.CrashReport do
  @moduledoc false

  # A handler of `:logger` that tells a test when the emulator logs the
  # report of a process that failed. The emulator keeps such a report in
  # its own queue, and gives it to the logger some time after the stop of
  # the process: a call to a different process cannot tell when it comes.
  # Thus a test that makes a process fail on purpose waits for the message
  # `{:crash_report, event}` in its `capture_log/1`.

  def attach(pid) do
    id = :"crash_report_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, __MODULE__, %{config: %{pid: pid}, level: :error})
    id
  end

  def detach(id), do: :logger.remove_handler(id)

  # The callback of the handler.
  def log(%{meta: %{error_logger: %{emulator: true}}} = event, %{config: %{pid: pid}}) do
    send(pid, {:crash_report, event})
    :ok
  end

  def log(_event, _config), do: :ok
end
