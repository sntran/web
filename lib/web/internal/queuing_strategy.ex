defmodule Web.Internal.QueuingStrategy do
  @moduledoc false

  # The queuing strategy of a stream, with the steps of the Streams Standard:
  # ExtractHighWaterMark, ExtractSizeAlgorithm, EnqueueValueWithSize,
  # DequeueValue, and the desired size.
  #
  # A strategy is a struct of this library (`Web.CountQueuingStrategy` or
  # `Web.ByteLengthQueuingStrategy`), or the dictionary `QueuingStrategy`
  # of the Standard: a map or a keyword list with the keys
  # `:high_water_mark` and `:size`.
  #
  # The size algorithm is `:count`, `:byte_length`, or the function of the
  # user. The stream process calls the two algorithms of the library. The
  # process that enqueues or writes the chunk calls the function of the
  # user, as the Standard does: thus the function can call the stream.
  #
  # JavaScript adds the sizes as double-precision numbers. An integer above
  # 2^53 is not exact in a double. Thus a sum of integers changes to a float
  # at that limit, and the result is the same as in JavaScript.

  alias Web.RangeError
  alias Web.TypeError

  @exact_limit 9_007_199_254_740_992

  @type high_water_mark :: number() | :infinity
  @type size :: :count | :byte_length | (term() -> term())

  @doc false
  # ExtractHighWaterMark and ExtractSizeAlgorithm. Returns
  # `{high_water_mark, size}`. Raises `Web.TypeError` for a size that is not
  # a function, and `Web.RangeError` for a high water mark that is NaN or
  # below zero.
  @spec extract!(term(), high_water_mark()) :: {high_water_mark(), size()}
  def extract!(nil, default_hwm), do: {default_hwm, :count}

  def extract!(%Web.CountQueuingStrategy{high_water_mark: hwm}, default_hwm),
    do: {high_water_mark!(hwm, default_hwm), :count}

  def extract!(%Web.ByteLengthQueuingStrategy{high_water_mark: hwm}, default_hwm),
    do: {high_water_mark!(hwm, default_hwm), :byte_length}

  # A struct of the user is a strategy object: the function `size/1` of its
  # module is its size function.
  def extract!(%module{} = strategy, default_hwm) do
    size = if function_exported?(module, :size, 1), do: &module.size/1, else: :count
    {high_water_mark!(Map.get(strategy, :high_water_mark), default_hwm), size}
  end

  def extract!(strategy, default_hwm) when is_list(strategy) or is_map(strategy) do
    size = size!(get(strategy, :size))
    {high_water_mark!(get(strategy, :high_water_mark), default_hwm), size}
  end

  def extract!(strategy, _default_hwm) do
    raise TypeError, "Invalid queuing strategy: #{inspect(strategy)}"
  end

  defp get(strategy, key) when is_list(strategy), do: Keyword.get(strategy, key)
  defp get(strategy, key), do: Map.get(strategy, key)

  defp size!(nil), do: :count
  defp size!(size) when is_function(size, 1), do: size

  defp size!(size) do
    raise TypeError, "The size of a queuing strategy must be a function, got: #{inspect(size)}"
  end

  @doc false
  # ExtractHighWaterMark: NaN and a value below zero are not permitted.
  @spec high_water_mark!(term(), high_water_mark()) :: high_water_mark()
  def high_water_mark!(nil, default_hwm), do: default_hwm
  def high_water_mark!(:infinity, _default_hwm), do: :infinity
  def high_water_mark!(hwm, _default_hwm) when is_number(hwm) and hwm >= 0, do: hwm

  def high_water_mark!(hwm, _default_hwm) do
    raise RangeError, "Invalid high water mark: #{inspect(hwm)}"
  end

  @doc false
  # Calls the size algorithm. Returns `{:ok, size}` with a valid size, or
  # `{:error, reason}`: the value that the function raised or threw, or a
  # `Web.RangeError` for a size that is not valid (EnqueueValueWithSize).
  @spec chunk_size(size(), term()) :: {:ok, number()} | {:error, term()}
  def chunk_size(:count, _chunk), do: {:ok, 1}
  def chunk_size(size, chunk), do: size |> call(chunk) |> validate()

  @doc false
  # Calls the size algorithm, and gives the result with no check. A value
  # that the function raises or throws is `{:thrown, kind, value,
  # stacktrace}`.
  @spec call(size(), term()) :: {:ok, term()} | {:thrown, atom(), term(), list()}
  def call(:count, _chunk), do: {:ok, 1}
  def call(:byte_length, chunk), do: call(&Web.ByteLengthQueuingStrategy.size/1, chunk)

  def call(size, chunk) when is_function(size, 1) do
    {:ok, size.(chunk)}
  catch
    kind, value -> {:thrown, kind, value, __STACKTRACE__}
  end

  @doc false
  # The checks of EnqueueValueWithSize: a size must be a number that is not
  # below zero, and not infinity.
  @spec validate({:ok, term()} | {:thrown, atom(), term(), list()}) ::
          {:ok, number()} | {:error, term()}
  def validate({:ok, size}) when is_number(size) and size >= 0, do: {:ok, size}

  def validate({:ok, size}) do
    {:error, RangeError.exception("Invalid size of a chunk: #{inspect(size)}")}
  end

  def validate({:thrown, kind, value, stacktrace}) do
    {:error, Exception.normalize(kind, value, stacktrace)}
  end

  @doc false
  # The total size of a queue after a chunk of `size` is added.
  @spec add(number(), number()) :: number()
  def add(total, size) when is_integer(total) and is_integer(size) do
    sum = total + size
    if abs(sum) <= @exact_limit, do: sum, else: :erlang.float(sum)
  end

  def add(total, size), do: total + size

  @doc false
  # DequeueValue: the total size after a chunk of `size` is removed. A
  # rounding error can give a value below zero: the total is then zero.
  @spec subtract(number(), number()) :: number()
  def subtract(total, size) do
    result = add(total, -size)
    if result < 0, do: 0, else: result
  end

  @doc false
  # The desired size: the high water mark minus the total size.
  @spec desired(high_water_mark(), number()) :: number() | :infinity
  def desired(:infinity, _total), do: :infinity
  def desired(hwm, total), do: add(hwm, -total)

  @doc false
  # Tells if a desired size is above zero.
  @spec positive?(number() | :infinity) :: boolean()
  def positive?(:infinity), do: true
  def positive?(desired), do: desired > 0
end
