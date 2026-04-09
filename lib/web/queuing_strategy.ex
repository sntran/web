defmodule Web.ByteLengthQueuingStrategy do
  defstruct [high_water_mark: 1]
  # coveralls-ignore-start
  def new(hwm), do: %__MODULE__{high_water_mark: hwm}
  def size(chunk), do: byte_size(chunk)
  # coveralls-ignore-stop
end

defmodule Web.CountQueuingStrategy do
  defstruct [high_water_mark: 1]
  def new(hwm), do: %__MODULE__{high_water_mark: hwm}
  def size(_), do: 1
end
