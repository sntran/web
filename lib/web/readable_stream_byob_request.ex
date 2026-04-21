defmodule Web.ReadableStreamBYOBRequest do
  @moduledoc """
  A pending BYOB request for a byte stream reader.
  """

  alias Web.ArrayBuffer
  alias Web.Uint8Array

  @response_message :web_stream_byob_response

  defstruct [:address, :view_byte_offset, :view_byte_length]

  @type t :: %__MODULE__{
          address: reference(),
          view_byte_offset: non_neg_integer(),
          view_byte_length: non_neg_integer()
        }

  @spec respond(t(), binary()) :: :ok
  def respond(%__MODULE__{address: address}, chunk) when is_binary(chunk) do
    send(address, {@response_message, address, {:chunk, chunk}})
    :ok
  end

  def respond(%__MODULE__{}, bytes_written)
      when is_integer(bytes_written) and bytes_written >= 0 do
    raise(
      ArgumentError,
      "BYOB requests must respond with a binary payload sent through the request capability."
    )
  end

  @spec respond_with_new_view(t(), Uint8Array.t() | binary()) :: :ok
  def respond_with_new_view(%__MODULE__{address: address}, %Uint8Array{} = view) do
    send(address, {@response_message, address, {:view, view}})
    :ok
  end

  def respond_with_new_view(%__MODULE__{} = request, view) when is_binary(view) do
    uint8_view = view |> ArrayBuffer.new() |> Uint8Array.new()
    respond_with_new_view(request, uint8_view)
  end
end
