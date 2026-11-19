defmodule Web.Internal.ContentDecoder do
  @moduledoc false

  # Decodes the content codings of a response body, as the step "handle
  # content codings" of the Fetch Standard.
  #
  # The decoder works on one chunk at a time, and it never has the full body
  # in memory. It gives its output to a function `emit` in pieces of
  # approximately `@piece_size` bytes. Thus a small compressed chunk that
  # expands to many bytes does not become one large binary. `emit` returns
  # `:cont`, or `:halt` to stop the decoding.
  #
  # The codings are `gzip`, `x-gzip`, `deflate`, and `zstd`. Erlang/OTP 28
  # and later have the module `:zstd`. A body with a coding that the decoder
  # does not know, for example `br`, is not decoded, as the Fetch Standard
  # specifies.
  #
  # Data that is not valid, and data that ends before the end of its
  # compressed form, raise `Web.Internal.ContentDecoder.Error`.

  import Bitwise

  defmodule Error do
    @moduledoc false
    defexception [:message, :coding]
  end

  @piece_size 65_536

  @zstd_magic 0xFD2FB528
  @skippable_magic 0x184D2A50..0x184D2A5F

  @doc "The value of the request header `accept-encoding`."
  @spec accept_encoding() :: String.t()
  def accept_encoding, do: "gzip, deflate, zstd"

  @doc """
  Makes the decoder for the headers of a response. Returns `nil` when the
  body needs no decoding, or has a coding that the decoder does not know.
  """
  @spec new([{String.t(), String.t()}]) :: [map()] | nil
  def new(headers) do
    codings =
      for {name, value} <- headers,
          String.downcase(name) == "content-encoding",
          coding <- String.split(value, ","),
          coding = coding |> String.trim() |> String.downcase(),
          coding not in ["", "identity"],
          do: coding

    cond do
      codings == [] -> nil
      Enum.all?(codings, &(&1 in ["gzip", "x-gzip", "deflate", "zstd"])) -> stages(codings)
      true -> nil
    end
  end

  # The codings are in the sequence in which the server applied them. The
  # decoder removes the last one first.
  defp stages(codings), do: codings |> Enum.reverse() |> Enum.map(&stage/1)

  defp stage(coding) when coding in ["gzip", "x-gzip"] do
    %{coding: coding, kind: :zlib, zlib: open_zlib(31), fed?: false}
  end

  # The zlib format, or raw deflate data: see `detect_deflate/3`.
  defp stage("deflate"), do: %{coding: "deflate", kind: :deflate, buffer: <<>>}

  defp stage("zstd") do
    {:ok, context} = :zstd.context(:decompress)
    %{coding: "zstd", kind: :zstd, context: context, frame: {:magic, <<>>}}
  end

  defp open_zlib(window_bits) do
    zlib = :zlib.open()
    :ok = :zlib.inflateInit(zlib, window_bits)
    zlib
  end

  @doc """
  Decodes one chunk of the body. Returns `:cont` or `:halt`, and the decoder.
  """
  @spec decode([map()], binary(), (binary() -> :cont | :halt)) :: {:cont | :halt, [map()]}
  def decode(stages, data, emit), do: feed(stages, data, emit)

  @doc """
  Ends the decoding at the end of the body. Gives the last output, and raises
  when the compressed data is not complete.
  """
  @spec finish([map()], (binary() -> :cont | :halt)) :: :cont | :halt
  def finish([], _emit), do: :cont

  def finish([stage | rest], emit) do
    {result, rest} = close_stage(stage, rest, emit)
    if result == :cont, do: finish(rest, emit), else: result
  end

  # ---------------------------------------------------------------------------
  # One stage after the other
  # ---------------------------------------------------------------------------

  defp feed(stages, <<>>, _emit), do: {:cont, stages}
  defp feed([], data, emit), do: {emit.(data), []}

  defp feed([stage | rest], data, emit) do
    {result, stage, rest} = run(stage, data, rest, emit)
    {result, [stage | rest]}
  end

  defp run(%{kind: :zlib, zlib: zlib} = stage, data, rest, emit) do
    {result, rest} = inflate(stage, safe_inflate(stage, zlib, data), [], 0, rest, emit)
    {result, %{stage | fed?: true}, rest}
  end

  defp run(%{kind: :deflate, buffer: buffer} = stage, data, rest, emit) do
    case detect_deflate(buffer <> data) do
      :more -> {:cont, %{stage | buffer: buffer <> data}, rest}
      window_bits -> run(deflate_stage(window_bits), buffer <> data, rest, emit)
    end
  end

  defp run(%{kind: :zstd} = stage, data, rest, emit) do
    frame = track(stage.frame, data)
    {result, rest} = decompress(stage, data, rest, emit)
    {result, %{stage | frame: frame}, rest}
  end

  # `deflate` in HTTP is the zlib format. Some servers send raw deflate
  # data, and browsers accept it. A zlib stream starts with two bytes: the
  # method 8 in the low bits of the first byte, and a check value.
  defp detect_deflate(data) when byte_size(data) < 2, do: :more

  defp detect_deflate(<<cmf, flg, _rest::binary>>) do
    if (cmf &&& 0x0F) == 8 and rem(cmf * 256 + flg, 31) == 0, do: 15, else: -15
  end

  defp deflate_stage(window_bits) do
    %{coding: "deflate", kind: :zlib, zlib: open_zlib(window_bits), fed?: false}
  end

  # The output of zlib comes in parts of 16 KiB at most. The stage collects
  # them into pieces of `@piece_size` bytes.
  defp inflate(stage, {:continue, out}, acc, size, rest, emit) do
    acc = [acc | out]
    size = size + IO.iodata_length(out)

    if size >= @piece_size do
      case feed(rest, IO.iodata_to_binary(acc), emit) do
        {:cont, rest} -> inflate(stage, safe_inflate(stage, stage.zlib, []), [], 0, rest, emit)
        {:halt, rest} -> {:halt, rest}
      end
    else
      inflate(stage, safe_inflate(stage, stage.zlib, []), acc, size, rest, emit)
    end
  end

  defp inflate(_stage, {:finished, out}, acc, _size, rest, emit) do
    feed(rest, IO.iodata_to_binary([acc | out]), emit)
  end

  defp safe_inflate(stage, zlib, data) do
    case :zlib.safeInflate(zlib, data) do
      {:need_dictionary, _adler, _out} -> invalid!(stage)
      result -> result
    end
  rescue
    ErlangError -> invalid!(stage)
  end

  defp decompress(stage, data, rest, emit) do
    case :zstd.stream(stage.context, data) do
      {:continue, remaining, out} ->
        case feed(rest, IO.iodata_to_binary(out), emit) do
          {:cont, rest} -> decompress(stage, remaining, rest, emit)
          {:halt, rest} -> {:halt, rest}
        end

      {:continue, out} ->
        feed(rest, IO.iodata_to_binary(out), emit)
    end
  rescue
    ErlangError -> invalid!(stage)
  end

  # ---------------------------------------------------------------------------
  # The end of the body
  # ---------------------------------------------------------------------------

  # A stage that got no data is an empty body.
  defp close_stage(%{kind: :zlib, fed?: false, zlib: zlib}, rest, _emit) do
    :zlib.close(zlib)
    {:cont, rest}
  end

  defp close_stage(%{kind: :zlib, zlib: zlib} = stage, rest, _emit) do
    :ok = :zlib.inflateEnd(zlib)
    :zlib.close(zlib)
    {:cont, rest}
  rescue
    ErlangError -> not_complete!(stage)
  end

  defp close_stage(%{kind: :deflate, buffer: <<>>}, rest, _emit), do: {:cont, rest}
  defp close_stage(%{kind: :deflate} = stage, _rest, _emit), do: not_complete!(stage)

  # The data must end at the end of a frame.
  defp close_stage(%{kind: :zstd, frame: {:magic, <<>>}} = stage, rest, emit) do
    {:done, out} = :zstd.finish(stage.context, <<>>)
    feed(rest, IO.iodata_to_binary(out), emit)
  end

  defp close_stage(%{kind: :zstd} = stage, _rest, _emit), do: not_complete!(stage)

  # ---------------------------------------------------------------------------
  # The frames of zstd
  #
  # The module `:zstd` does not tell where a frame ends. Thus the decoder
  # follows the structure of the frames of RFC 8878: the header, each block,
  # and the checksum. Data that ends in a frame is not complete.
  # ---------------------------------------------------------------------------

  # A field to skip: `size` bytes, then the state `next`.
  defp track({:skip, size, next}, data), do: skip(size, data, next)
  defp track(state, <<>>), do: state

  defp track({:magic, buffer}, data) do
    case take(4, buffer, data) do
      {:more, buffer} ->
        {:magic, buffer}

      {<<@zstd_magic::32-little>>, rest} ->
        track(:descriptor, rest)

      {<<magic::32-little>>, rest} when magic in @skippable_magic ->
        track({:skip_size, <<>>}, rest)

      {_other, _rest} ->
        raise Error, message: "The data is not a zstd frame.", coding: "zstd"
    end
  end

  # A skippable frame has its size after its magic number.
  defp track({:skip_size, buffer}, data) do
    case take(4, buffer, data) do
      {:more, buffer} -> {:skip_size, buffer}
      {<<size::32-little>>, rest} -> track({:skip, size, {:magic, <<>>}}, rest)
    end
  end

  # The first byte of the frame header tells the size of the other fields.
  defp track(:descriptor, <<descriptor, rest::binary>>) do
    if (descriptor &&& 0x08) != 0 do
      raise Error, message: "The zstd frame header is not valid.", coding: "zstd"
    end

    single_segment = descriptor >>> 5 &&& 1
    checksum? = (descriptor &&& 0x04) != 0
    window = 1 - single_segment
    dictionary = elem({0, 1, 2, 4}, descriptor &&& 0x03)
    content_size = elem({single_segment, 2, 4, 8}, descriptor >>> 6)

    track({:skip, window + dictionary + content_size, {:block, <<>>, checksum?}}, rest)
  end

  defp track({:block, buffer, checksum?}, data) do
    case take(3, buffer, data) do
      {:more, buffer} ->
        {:block, buffer, checksum?}

      {<<header::24-little>>, rest} ->
        last? = (header &&& 1) == 1

        content_size =
          case header >>> 1 &&& 0x03 do
            # A block of one repeated byte has that byte only.
            1 -> 1
            3 -> raise Error, message: "The zstd block type is not valid.", coding: "zstd"
            _raw_or_compressed -> header >>> 3
          end

        track({:skip, content_size, after_block(last?, checksum?)}, rest)
    end
  end

  defp after_block(false, checksum?), do: {:block, <<>>, checksum?}
  defp after_block(true, true), do: {:skip, 4, {:magic, <<>>}}
  defp after_block(true, false), do: {:magic, <<>>}

  defp skip(size, data, next) when byte_size(data) >= size do
    track(next, binary_part(data, size, byte_size(data) - size))
  end

  defp skip(size, data, next), do: {:skip, size - byte_size(data), next}

  defp take(size, buffer, data) when byte_size(buffer) + byte_size(data) < size do
    {:more, buffer <> data}
  end

  defp take(size, buffer, data) do
    needed = size - byte_size(buffer)
    {buffer <> binary_part(data, 0, needed), binary_part(data, needed, byte_size(data) - needed)}
  end

  @spec invalid!(map()) :: no_return()
  defp invalid!(stage) do
    raise Error, message: "The #{stage.coding} data is not valid.", coding: stage.coding
  end

  @spec not_complete!(map()) :: no_return()
  defp not_complete!(stage) do
    raise Error, message: "The #{stage.coding} data is not complete.", coding: stage.coding
  end
end
