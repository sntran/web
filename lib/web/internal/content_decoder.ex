defmodule Web.Internal.ContentDecoder do
  @moduledoc false

  # Decodes the content codings of a response body, as the step "handle
  # content codings" of the Fetch Standard.
  #
  # The decoder works on one chunk at a time, and it never has the full body
  # in memory. The caller gives each chunk of the body with `push/2`, and
  # takes the output with `pull/1`, one piece at a time: a piece has
  # approximately `@piece_size` bytes. Thus a small compressed chunk that
  # expands to many bytes does not become one large binary, and the caller
  # takes the next piece only when it has space for it: the backpressure.
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
          content_encoding?(name),
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

  # The HTTP client gives the names in lower case. A name in a different
  # case is converted only when it has the length of `content-encoding`.
  defp content_encoding?("content-encoding"), do: true

  defp content_encoding?(name) when byte_size(name) == 16,
    do: String.downcase(name, :ascii) == "content-encoding"

  defp content_encoding?(_name), do: false

  # The codings are in the sequence in which the server applied them. The
  # decoder removes the last one first.
  defp stages(codings), do: codings |> Enum.reverse() |> Enum.map(&stage/1)

  # Each stage has the queue of its input, and `ended?` when its input has
  # no more chunks.
  defp stage(coding) when coding in ["gzip", "x-gzip"], do: zlib_stage(coding, 31)

  # The zlib format, or raw deflate data: see `detect_deflate/1`.
  defp stage("deflate") do
    %{coding: "deflate", kind: :deflate, buffer: <<>>, input: :queue.new(), ended?: false}
  end

  defp stage("zstd") do
    {:ok, context} = :zstd.context(:decompress)

    %{
      coding: "zstd",
      kind: :zstd,
      context: context,
      frame: {:magic, <<>>},
      remaining: <<>>,
      input: :queue.new(),
      ended?: false,
      done?: false
    }
  end

  defp zlib_stage(coding, window_bits) do
    zlib = :zlib.open()
    :ok = :zlib.inflateInit(zlib, window_bits)

    %{
      coding: coding,
      kind: :zlib,
      zlib: zlib,
      fed?: false,
      continuing?: false,
      input: :queue.new(),
      ended?: false,
      done?: false
    }
  end

  @doc "Gives a chunk of the body to the decoder."
  @spec push([map()], binary()) :: [map()]
  def push([first | rest], data), do: [add_input(first, data) | rest]

  @doc "The body has no more chunks."
  @spec finish([map()]) :: [map()]
  def finish([first | rest]), do: [%{first | ended?: true} | rest]

  @doc """
  Takes the next piece of the output. Returns `{:more, stages}` when the
  decoder needs the next chunk of the body, and `{:done, stages}` after the
  last piece of a body that ended. Raises when the data is not valid or not
  complete.
  """
  @spec pull([map()]) :: {:piece, binary(), [map()]} | {:more, [map()]} | {:done, [map()]}
  def pull(stages), do: collect(stages, [], 0)

  # The output of a stage comes in small parts: zlib gives 16 KiB at most.
  # The pieces have `@piece_size` bytes when the data has them.
  defp collect(stages, acc, size) when size >= @piece_size do
    {:piece, IO.iodata_to_binary(acc), stages}
  end

  defp collect(stages, acc, size) do
    case pull_chain(stages) do
      {:piece, piece, stages} -> collect(stages, [acc | piece], size + byte_size(piece))
      {status, stages} when size == 0 -> {status, stages}
      {_status, stages} -> {:piece, IO.iodata_to_binary(acc), stages}
    end
  end

  defp add_input(stage, <<>>), do: stage
  defp add_input(stage, data), do: %{stage | input: :queue.in(data, stage.input)}

  # ---------------------------------------------------------------------------
  # One stage after the other
  # ---------------------------------------------------------------------------

  # The last stage gives the output. A stage that needs input takes the
  # output of the stage before it.
  defp pull_chain(stages) do
    {before, [last]} = Enum.split(stages, -1)

    case pull_stage(last) do
      {:more, last} when before != [] ->
        case pull_chain(before) do
          {:piece, piece, before} -> pull_chain(before ++ [add_input(last, piece)])
          {:more, before} -> {:more, before ++ [last]}
          {:done, before} -> pull_chain(before ++ [%{last | ended?: true}])
        end

      {status, last} ->
        {status, before ++ [last]}

      {:piece, piece, last} ->
        {:piece, piece, before ++ [last]}
    end
  end

  # zlib keeps the input that it did not use: a stage that continues gets
  # more output with no new input.
  defp pull_stage(%{kind: :zlib, continuing?: true} = stage) do
    inflated(stage, safe_inflate(stage, stage.zlib, []))
  end

  defp pull_stage(%{kind: :zlib, done?: true} = stage), do: {:done, stage}

  defp pull_stage(%{kind: :zlib} = stage) do
    case :queue.out(stage.input) do
      {{:value, data}, input} ->
        stage = %{stage | input: input, fed?: true}
        inflated(stage, safe_inflate(stage, stage.zlib, data))

      {:empty, _input} when stage.ended? ->
        close_zlib(stage)
        {:done, %{stage | done?: true}}

      {:empty, _input} ->
        {:more, stage}
    end
  end

  # The first two bytes tell the format of the deflate data.
  defp pull_stage(%{kind: :deflate} = stage) do
    case :queue.out(stage.input) do
      {{:value, data}, input} ->
        buffer = stage.buffer <> data

        case detect_deflate(buffer) do
          :more ->
            pull_stage(%{stage | buffer: buffer, input: input})

          window_bits ->
            zlib = zlib_stage("deflate", window_bits)
            pull_stage(%{zlib | input: :queue.in_r(buffer, input), ended?: stage.ended?})
        end

      {:empty, _input} when stage.ended? and stage.buffer == <<>> ->
        {:done, stage}

      {:empty, _input} when stage.ended? ->
        not_complete!(stage)

      {:empty, _input} ->
        {:more, stage}
    end
  end

  defp pull_stage(%{kind: :zstd, done?: true} = stage), do: {:done, stage}

  defp pull_stage(%{kind: :zstd, remaining: <<>>} = stage) do
    case :queue.out(stage.input) do
      {{:value, data}, input} ->
        decompress(%{stage | input: input, frame: track(stage.frame, data)}, data)

      # The data must end at the end of a frame.
      {:empty, _input} when stage.ended? and stage.frame == {:magic, <<>>} ->
        {:done, out} = :zstd.finish(stage.context, <<>>)
        {:piece, IO.iodata_to_binary(out), %{stage | done?: true}}

      {:empty, _input} when stage.ended? ->
        not_complete!(stage)

      {:empty, _input} ->
        {:more, stage}
    end
  end

  defp pull_stage(%{kind: :zstd} = stage), do: decompress(stage, stage.remaining)

  # `deflate` in HTTP is the zlib format. Some servers send raw deflate
  # data, and browsers accept it. A zlib stream starts with two bytes: the
  # method 8 in the low bits of the first byte, and a check value.
  defp detect_deflate(data) when byte_size(data) < 2, do: :more

  defp detect_deflate(<<cmf, flg, _rest::binary>>) do
    if (cmf &&& 0x0F) == 8 and rem(cmf * 256 + flg, 31) == 0, do: 15, else: -15
  end

  defp inflated(stage, {:continue, out}),
    do: {:piece, IO.iodata_to_binary(out), %{stage | continuing?: true}}

  defp inflated(stage, {:finished, out}),
    do: {:piece, IO.iodata_to_binary(out), %{stage | continuing?: false}}

  defp safe_inflate(stage, zlib, data) do
    case :zlib.safeInflate(zlib, data) do
      {:need_dictionary, _adler, _out} -> invalid!(stage)
      result -> result
    end
  rescue
    ErlangError -> invalid!(stage)
  end

  # `:zstd` gives the input that it did not use when its output is full.
  defp decompress(stage, data) do
    case :zstd.stream(stage.context, data) do
      {:continue, remaining, out} ->
        {:piece, IO.iodata_to_binary(out), %{stage | remaining: remaining}}

      {:continue, out} ->
        {:piece, IO.iodata_to_binary(out), %{stage | remaining: <<>>}}
    end
  rescue
    ErlangError -> invalid!(stage)
  end

  # A stage that got no data is an empty body.
  defp close_zlib(%{fed?: false, zlib: zlib}), do: :zlib.close(zlib)

  defp close_zlib(%{zlib: zlib} = stage) do
    :ok = :zlib.inflateEnd(zlib)
    :zlib.close(zlib)
  rescue
    ErlangError -> not_complete!(stage)
  end

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
