defmodule Web.TestFakeBrotliNif do
  @moduledoc false

  # A module in the place of the module `:brotli_nif` of the Hex package
  # `brotli`, for the tests of the setting `brotli: :native`. It has the
  # functions of that module that the library calls, with the same results,
  # and it decodes with the decoder of the library.
  #
  # Its ring buffer has 100000 bytes, and a take gives 40000 bytes at most:
  # thus the library must call it again and again. At the end of a stream
  # it first gives `{:more_output, unused}` while it has output, and then
  # `:ok` for each input, as the C library does.
  #
  # `install/0` puts the module in the memory only. Thus after `remove/0`
  # the VM has no module of that name. A decoder keeps its state in the
  # process dictionary of the process that uses it: the library uses a
  # decoder in one process, and the state goes away with that process.

  # The quoted code takes this alias.
  alias Web.Internal.Brotli.Decoder

  @code (quote do
           defmodule :brotli_nif do
             @moduledoc false

             @ring 100_000
             @take 40_000
             @slice 16

             def decoder_create do
               :counters.add(:persistent_term.get(Web.TestFakeBrotliNif), 1, 1)
               ref = make_ref()

               state = %{
                 decoder: Decoder.new(),
                 output: <<>>,
                 state: :running
               }

               Process.put({__MODULE__, ref}, state)
               ref
             end

             def decoder_decompress_stream(ref, input) do
               {result, state} = stream(Process.get({__MODULE__, ref}), input)
               Process.put({__MODULE__, ref}, state)
               result
             end

             def decoder_is_finished(ref) do
               %{state: state, output: output} = Process.get({__MODULE__, ref})
               state == :end and output == <<>>
             end

             def decoder_take_output(ref) do
               %{output: output} = state = Process.get({__MODULE__, ref})
               size = min(byte_size(output), @take)
               rest = binary_part(output, size, byte_size(output) - size)
               Process.put({__MODULE__, ref}, %{state | output: rest})
               binary_part(output, 0, size)
             end

             # The decoder takes the input in slices, and stops when its ring
             # buffer is full. Then the bytes that it did not take are the
             # unused bytes.
             defp stream(state, input) do
               state = drain(state)

               cond do
                 state.state == :error -> {:error, state}
                 state.state == :end -> finish(state, input)
                 byte_size(state.output) >= @ring -> {{:more_output, byte_size(input)}, state}
                 input == <<>> -> wait(state)
                 true -> take_slice(state, input)
               end
             end

             # At the end of a stream, the C library first gives the output
             # of the ring buffer, then `:ok`.
             defp finish(%{output: <<>>} = state, _input), do: {:ok, state}
             defp finish(state, input), do: {{:more_output, byte_size(input)}, state}

             defp wait(%{output: <<>>} = state), do: {{:more_input, 0}, state}
             defp wait(state), do: {{:more_output, 0}, state}

             defp take_slice(state, input) do
               size = min(@slice, byte_size(input))
               decoder = Decoder.append(state.decoder, binary_part(input, 0, size))

               stream(
                 %{state | decoder: decoder},
                 binary_part(input, size, byte_size(input) - size)
               )
             end

             defp drain(%{state: :running, output: output} = state)
                  when byte_size(output) < @ring do
               case Decoder.run(state.decoder, @ring - byte_size(output)) do
                 {:output, piece, decoder} ->
                   drain(%{state | decoder: decoder, output: output <> piece})

                 {:more, decoder} ->
                   %{state | decoder: decoder}

                 {:end, decoder} ->
                   %{state | decoder: decoder, state: :end}

                 {:error, :invalid} ->
                   %{state | state: :error}
               end
             end

             defp drain(state), do: state
           end
         end)

  @doc "Puts the module `:brotli_nif` in the memory of the VM."
  def install do
    :persistent_term.put(__MODULE__, :counters.new(1, []))
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)
    Code.compile_quoted(@code)
    Code.put_compiler_option(:ignore_module_conflict, previous)
    :ok
  end

  @doc "Removes the module `:brotli_nif`."
  def remove do
    :code.purge(:brotli_nif)
    :code.delete(:brotli_nif)
    :code.purge(:brotli_nif)
    :ok
  end

  @doc "The number of decoders that the module made after `install/0`."
  def created, do: :counters.get(:persistent_term.get(__MODULE__), 1)
end
