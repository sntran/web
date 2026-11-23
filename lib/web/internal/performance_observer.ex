defmodule Web.Internal.PerformanceObserver do
  @moduledoc false

  # The steps of `Web.PerformanceObserver` in the process that has a
  # handle: the conversion of the options, and the warnings. The observer is
  # in the timeline server of its global object: see
  # `Web.Internal.PerformanceTimeline`.

  require Logger

  alias Web.DOMException
  alias Web.Internal.MessageTarget
  alias Web.Internal.PerformanceTimeline
  alias Web.PerformanceObserver

  @doc """
  The steps of `observe(options)`. The observer observes its global
  object, as the relevant global object of the Standard: not the calling
  process.
  """
  @spec observe(PerformanceObserver.t(), keyword()) :: :ok
  def observe(%PerformanceObserver{} = observer, options) do
    request = options |> init!() |> request()

    case MessageTarget.call(observer, {:observe, request}) do
      {:registered, ignored} ->
        if ignored != [], do: warn("ignores the entry types #{inspect(ignored)}")
        :ok

      {:aborted, ignored} ->
        warn(
          "does not observe: the options have no supported entry type, got: #{inspect(ignored)}"
        )

      :invalid_modification ->
        raise DOMException,
          name: "InvalidModificationError",
          message:
            "An observer that observes with :entry_types cannot observe with :type, " <>
              "and an observer that observes with :type cannot observe with :entry_types."

      # The observer stopped with its global object: the call has no effect.
      {:error, _reason} ->
        :ok
    end
  end

  @spec disconnect(PerformanceObserver.t()) :: :ok
  def disconnect(%PerformanceObserver{} = observer) do
    _reply = MessageTarget.call(observer, :disconnect)
    :ok
  end

  @spec take_records(PerformanceObserver.t()) :: [Web.Performance.entry()]
  def take_records(%PerformanceObserver{} = observer) do
    case MessageTarget.call(observer, :take_records) do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end

  # The members of `PerformanceObserverInit`, as Web IDL converts a
  # dictionary. A member with the value `nil` is not present, as a member
  # with the value `undefined`. The function ignores each other option.
  defp init!(options) do
    if not Keyword.keyword?(options) do
      raise Web.TypeError, "The options must be a keyword list, got: #{inspect(options)}"
    end

    %{
      buffered: member(options, :buffered, &(&1 != false)),
      entry_types: member(options, :entry_types, &entry_types!/1),
      type: member(options, :type, &Web.Performance.__text__/1)
    }
  end

  defp member(options, key, convert) do
    case Keyword.get(options, key) do
      nil -> nil
      value -> convert.(value)
    end
  end

  defp entry_types!(types) when is_list(types), do: Enum.map(types, &Web.Performance.__text__/1)

  defp entry_types!(types) do
    raise Web.TypeError, "The option :entry_types must be a list, got: #{inspect(types)}"
  end

  # Steps 2 and 3 of `observe(options)`. The server does the other steps.
  defp request(%{entry_types: nil, type: nil}) do
    raise Web.TypeError, "The options must have :entry_types or :type."
  end

  defp request(%{entry_types: types, type: nil, buffered: nil}) when is_list(types) do
    {:multiple, types}
  end

  defp request(%{entry_types: types}) when is_list(types) do
    raise Web.TypeError, "The option :entry_types cannot have other options."
  end

  defp request(%{type: type, buffered: buffered}), do: {:single, type, buffered == true}

  # The Standard tells the user agent to notify the developer when the
  # observer ignores an entry type, and when the steps abort.
  defp warn(text) do
    Logger.warning(
      "The PerformanceObserver #{text}. The supported entry types are " <>
        "#{inspect(PerformanceTimeline.supported_entry_types())}."
    )
  end
end
