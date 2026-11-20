defmodule Web.Internal.ByteStreamController do
  @moduledoc false

  # The internal slots and the abstract operations of a
  # ReadableByteStreamController of the Streams Standard (4.7, 4.8, and
  # 4.9.5).
  #
  # The stream process of `Web.Stream` keeps this state in its field
  # `bytes`. Each operation takes the data of the stream process, and
  # returns `{data, actions, transition}`:
  #
  #   * `actions` are actions of `:gen_statem`: the replies, and the internal
  #     event `:maybe_pull` for ReadableByteStreamControllerCallPullIfNeeded;
  #   * `transition` is `:none`, `:close` for ReadableStreamClose, or
  #     `{:error, reason}` for ReadableByteStreamControllerError.
  #
  # The field `queue` of the stream process holds the readable byte stream
  # queue entries `{buffer, byte_offset, byte_length}`, and the field
  # `total_queued_size` is [[queueTotalSize]]. The field `read_requests`
  # holds the read requests of a default reader. Thus the rules of the
  # engine for the queue, the desired size, and the lock apply also to a
  # byte stream.
  #
  # The views of this library are `Web.Uint8Array` values. Thus the element
  # size of each pull-into descriptor is 1, and its view constructor is
  # %Uint8Array%.

  alias Web.ArrayBuffer
  alias Web.RangeError
  alias Web.ReadableStreamBYOBRequest
  alias Web.TypeError
  alias Web.Uint8Array

  defstruct pull_intos: [],
            byob_request: nil,
            auto_allocate_chunk_size: nil,
            close_requested: false,
            read_into_requests: :queue.new()

  @type t :: %__MODULE__{}

  @empty_buffer "The buffer of the view has no bytes, or it is detached."
  @detached_request "The buffer of the BYOB request is detached."
  @invalidated "The BYOB request is no longer valid."

  @doc false
  def new(auto_allocate_chunk_size),
    do: %__MODULE__{auto_allocate_chunk_size: auto_allocate_chunk_size}

  # ---------------------------------------------------------------------------
  # The methods of ReadableByteStreamController
  # ---------------------------------------------------------------------------

  @doc false
  # The steps of `enqueue(chunk)`. `from` is `nil` for a chunk of the code of
  # this library, which gets no reply.
  def enqueue(data, state, %Uint8Array{} = chunk, from) do
    case enqueue_refusal(data, state, chunk) do
      nil ->
        data
        |> start()
        |> enqueue_chunk(chunk, from)
        |> finish()

      error ->
        data |> start() |> reply(from, {:error, error}) |> finish()
    end
  end

  defp enqueue_refusal(data, state, chunk) do
    cond do
      chunk.byte_length == 0 -> TypeError.exception("The chunk has no bytes.")
      ArrayBuffer.byte_length(chunk.buffer) == 0 -> TypeError.exception(@empty_buffer)
      data.bytes.close_requested -> TypeError.exception("The stream has a close request.")
      state != :readable -> TypeError.exception("The stream is not readable.")
      true -> nil
    end
  end

  # ReadableByteStreamControllerEnqueue, after the checks of the method.
  defp enqueue_chunk(acc, chunk, from) do
    transferred = transfer(chunk.buffer)

    case pull_intos(acc) do
      [first | _rest] ->
        if ArrayBuffer.detached?(first.buffer) do
          reply(acc, from, {:error, TypeError.exception(@detached_request)})
        else
          acc
          |> invalidate_byob_request()
          |> update_head(&%{&1 | buffer: transfer(&1.buffer)})
          |> enqueue_detached_head()
          |> enqueue_for_reader(transferred, chunk.byte_offset, chunk.byte_length)
          |> reply(from, :ok)
        end

      [] ->
        acc
        |> enqueue_for_reader(transferred, chunk.byte_offset, chunk.byte_length)
        |> reply(from, :ok)
    end
  end

  # The head descriptor of a reader that released its lock: its bytes go to
  # the queue.
  defp enqueue_detached_head(acc) do
    case pull_intos(acc) do
      [%{reader_type: :none} = first | _rest] -> enqueue_detached_pull_into_to_queue(acc, first)
      _other -> acc
    end
  end

  defp enqueue_for_reader(acc, buffer, byte_offset, byte_length) do
    acc =
      case reader_type(acc) do
        :default ->
          acc
          |> process_read_requests_using_queue()
          |> enqueue_for_default_reader(buffer, byte_offset, byte_length)

        :byob ->
          acc
          |> enqueue_chunk_to_queue(buffer, byte_offset, byte_length)
          |> commit_filled_pull_intos()

        nil ->
          enqueue_chunk_to_queue(acc, buffer, byte_offset, byte_length)
      end

    call_pull_if_needed(acc)
  end

  # The chunk goes to the queue, or to the first read that waits. That read
  # does not use the buffer of its auto-allocated BYOB request.
  defp enqueue_for_default_reader(acc, buffer, byte_offset, byte_length) do
    cond do
      :queue.is_empty(field(acc, :read_requests)) ->
        enqueue_chunk_to_queue(acc, buffer, byte_offset, byte_length)

      pull_intos(acc) == [] ->
        fulfill_read_request(acc, view(buffer, byte_offset, byte_length), false)

      true ->
        {_descriptor, acc} = shift_pending_pull_into(acc)
        fulfill_read_request(acc, view(buffer, byte_offset, byte_length), false)
    end
  end

  @doc false
  # The steps of `close()`.
  def close(data, state, from) do
    acc = start(data)

    cond do
      data.bytes.close_requested ->
        acc |> reply(from, {:error, TypeError.exception("The stream has a close request.")})

      state != :readable ->
        acc |> reply(from, {:error, TypeError.exception("The stream is not readable.")})

      # ReadableByteStreamControllerClose. The stream closes when a read
      # takes the last bytes of the queue.
      data.total_queued_size > 0 ->
        acc |> update_bytes(&%{&1 | close_requested: true}) |> reply(from, :ok)

      true ->
        acc |> close_stream() |> reply(from, :ok)
    end
    |> finish()
  end

  @doc false
  # The `byobRequest` getter: ReadableByteStreamControllerGetBYOBRequest.
  def byob_request(data, from) do
    acc = start(data)

    case {data.bytes.byob_request, data.bytes.pull_intos} do
      {nil, [first | _rest]} ->
        view =
          view(
            first.buffer,
            first.byte_offset + first.bytes_filled,
            first.byte_length - first.bytes_filled
          )

        request = %ReadableStreamBYOBRequest{controller_pid: self(), id: make_ref(), view: view}
        acc |> update_bytes(&%{&1 | byob_request: request}) |> reply(from, request)

      {request, _pull_intos} ->
        reply(acc, from, request)
    end
    |> finish()
  end

  @doc false
  # Tells whether the request `id` is the current BYOB request: the
  # attribute `view` of an invalidated request is null.
  def current_request?(data, id) do
    match?(%ReadableStreamBYOBRequest{id: ^id}, data.bytes.byob_request)
  end

  # ---------------------------------------------------------------------------
  # The reads
  # ---------------------------------------------------------------------------

  @doc false
  # [[PullSteps]](readRequest) for a default reader of a readable stream.
  def pull_steps(data, from) do
    acc = start(data)

    cond do
      data.total_queued_size > 0 ->
        fill_read_request_from_queue(acc, from)

      is_integer(data.bytes.auto_allocate_chunk_size) ->
        size = data.bytes.auto_allocate_chunk_size

        descriptor =
          descriptor(ArrayBuffer.new(size), 0, size, 1, :default)

        acc
        |> update_bytes(&%{&1 | pull_intos: &1.pull_intos ++ [descriptor]})
        |> add_read_request(from)
        |> call_pull_if_needed()

      true ->
        acc |> add_read_request(from) |> call_pull_if_needed()
    end
    |> finish()
  end

  @doc false
  # ReadableByteStreamControllerPullInto, for a read of a BYOB reader. The
  # stream is readable or closed. The method `read(view)` checked the view
  # and `min`, but a different process can detach the buffer after the
  # checks.
  def pull_into(data, state, from, %Uint8Array{} = view, min) do
    acc = start(data)

    if ArrayBuffer.detached?(view.buffer) do
      acc |> reply(from, {:error, TypeError.exception(@empty_buffer)})
    else
      buffer = transfer(view.buffer)
      descriptor = descriptor(buffer, view.byte_offset, view.byte_length, min, :byob)
      pull_into_descriptor(acc, state, from, descriptor)
    end
    |> finish()
  end

  defp pull_into_descriptor(acc, state, from, descriptor) do
    cond do
      pull_intos(acc) != [] ->
        acc |> append_pull_into(descriptor) |> add_read_into_request(from)

      state == :closed ->
        reply(acc, from, {:done, view(descriptor.buffer, descriptor.byte_offset, 0)})

      field(acc, :total_queued_size) > 0 ->
        pull_into_from_queue(acc, from, descriptor)

      true ->
        wait_for_pull_into(acc, from, descriptor)
    end
  end

  defp pull_into_from_queue(acc, from, descriptor) do
    {ready, descriptor, acc} = fill_pull_into_descriptor_from_queue(acc, descriptor)

    cond do
      ready ->
        filled_view = convert_pull_into_descriptor(descriptor)
        acc |> handle_queue_drain() |> reply(from, {:ok, filled_view})

      bytes(acc).close_requested ->
        error = TypeError.exception("The stream closed before the view has its minimum bytes.")
        acc |> error_stream(error) |> reply(from, {:error, {:errored, error}})

      true ->
        wait_for_pull_into(acc, from, descriptor)
    end
  end

  defp wait_for_pull_into(acc, from, descriptor) do
    acc
    |> append_pull_into(descriptor)
    |> add_read_into_request(from)
    |> call_pull_if_needed()
  end

  # ---------------------------------------------------------------------------
  # The methods of ReadableStreamBYOBRequest
  # ---------------------------------------------------------------------------

  @doc false
  # The steps of `respond(bytesWritten)` of the request `id`. `view` is the
  # view of the request as the caller has it: its buffer has the bytes that
  # the caller wrote. See `adopt/2`.
  def respond(data, state, from, id, bytes_written, %Uint8Array{} = view) do
    acc = start(data)

    cond do
      not current_request?(data, id) ->
        reply(acc, from, {:error, TypeError.exception(@invalidated)})

      ArrayBuffer.detached?(view.buffer) ->
        reply(acc, from, {:error, TypeError.exception(@detached_request)})

      true ->
        [first | _rest] = data.bytes.pull_intos

        case respond_refusal(state, first, bytes_written) do
          nil ->
            acc
            |> update_head(&%{&1 | buffer: transfer(adopt(&1.buffer, view.buffer))})
            |> respond_internal(state, bytes_written)
            |> reply(from, :ok)

          error ->
            reply(acc, from, {:error, error})
        end
    end
    |> finish()
  end

  defp respond_refusal(:closed, _first, bytes_written) when bytes_written != 0 do
    TypeError.exception("A request of a closed stream needs the response 0.")
  end

  defp respond_refusal(:closed, _first, _bytes_written), do: nil

  defp respond_refusal(_readable, _first, 0) do
    TypeError.exception("A request of a readable stream needs a response above 0.")
  end

  defp respond_refusal(_readable, first, bytes_written) do
    if first.bytes_filled + bytes_written > first.byte_length do
      RangeError.exception("The response is larger than the view of the request.")
    end
  end

  # The request view has the same buffer as the head descriptor, maybe with
  # bytes that the caller wrote. A struct of a buffer is a value: the caller
  # gives the buffer as it is now.
  defp adopt(buffer, written) do
    if ArrayBuffer.identity(buffer) == ArrayBuffer.identity(written), do: written, else: buffer
  end

  @doc false
  # The steps of `respondWithNewView(view)` of the request `id`.
  def respond_with_new_view(data, state, from, id, %Uint8Array{} = view) do
    acc = start(data)

    cond do
      not current_request?(data, id) ->
        reply(acc, from, {:error, TypeError.exception(@invalidated)})

      ArrayBuffer.detached?(view.buffer) ->
        reply(acc, from, {:error, TypeError.exception("The buffer of the view is detached.")})

      true ->
        [first | _rest] = data.bytes.pull_intos

        case new_view_refusal(state, first, view) do
          nil ->
            acc
            |> update_head(&%{&1 | buffer: transfer(view.buffer)})
            |> respond_internal(state, view.byte_length)
            |> reply(from, :ok)

          error ->
            reply(acc, from, {:error, error})
        end
    end
    |> finish()
  end

  defp new_view_refusal(state, first, view) do
    cond do
      state == :closed and view.byte_length != 0 ->
        TypeError.exception("A request of a closed stream needs a view of 0 bytes.")

      state != :closed and view.byte_length == 0 ->
        TypeError.exception("A request of a readable stream needs a view above 0 bytes.")

      first.byte_offset + first.bytes_filled != view.byte_offset ->
        RangeError.exception("The view does not start at the start of the request view.")

      first.buffer_byte_length != ArrayBuffer.byte_length(view.buffer) ->
        RangeError.exception("The buffer of the view has a different length.")

      first.bytes_filled + view.byte_length > first.byte_length ->
        RangeError.exception("The view is larger than the view of the request.")

      true ->
        nil
    end
  end

  # ReadableByteStreamControllerRespondInternal.
  defp respond_internal(acc, state, bytes_written) do
    [first | _rest] = pull_intos(acc)
    acc = invalidate_byob_request(acc)

    acc =
      if state == :closed,
        do: respond_in_closed_state(acc, first),
        else: respond_in_readable_state(acc, bytes_written)

    call_pull_if_needed(acc)
  end

  defp respond_in_closed_state(acc, first) do
    acc =
      if first.reader_type == :none, do: acc |> shift_pending_pull_into() |> elem(1), else: acc

    if reader_type(acc) == :byob do
      count = :queue.len(bytes(acc).read_into_requests)
      {filled, rest} = Enum.split(pull_intos(acc), count)

      Enum.reduce(filled, update_bytes(acc, &%{&1 | pull_intos: rest}), fn descriptor, acc ->
        commit_pull_into_descriptor(acc, descriptor, true)
      end)
    else
      acc
    end
  end

  defp respond_in_readable_state(acc, bytes_written) do
    acc = update_head(acc, &%{&1 | bytes_filled: &1.bytes_filled + bytes_written})
    [descriptor | _rest] = pull_intos(acc)

    cond do
      descriptor.reader_type == :none ->
        acc
        |> enqueue_detached_pull_into_to_queue(descriptor)
        |> commit_filled_pull_intos()

      # A descriptor that has not its minimum bytes stays at the head of the
      # queue: the source can continue to fill it.
      descriptor.bytes_filled < descriptor.minimum_fill ->
        acc

      true ->
        {descriptor, acc} = shift_pending_pull_into(acc)
        {acc, filled} = process_pull_into_descriptors_using_queue(acc)

        Enum.reduce([descriptor | filled], acc, &commit_pull_into_descriptor(&2, &1, false))
    end
  end

  # ---------------------------------------------------------------------------
  # The internal methods
  # ---------------------------------------------------------------------------

  @doc false
  # [[ReleaseSteps]](), and the rejection of the read-into requests of a
  # BYOB reader that releases its lock (ReadableStreamBYOBReaderRelease).
  # The request that the source has stays: a response puts its bytes in the
  # queue.
  def release(%{bytes: bytes} = data) do
    pull_intos =
      case bytes.pull_intos do
        [first | _rest] -> [%{first | reader_type: :none}]
        [] -> []
      end

    actions =
      for from <- :queue.to_list(bytes.read_into_requests),
          do: {:reply, from, {:error, :not_locked_by_reader}}

    {%{data | bytes: %{bytes | pull_intos: pull_intos, read_into_requests: :queue.new()}},
     actions}
  end

  @doc false
  # The steps of ReadableStreamCancel for the read-into requests (their
  # close steps get undefined), and ReadableByteStreamControllerClearPendingPullIntos
  # of [[CancelSteps]]. The engine resets the queue.
  def cancel(%{bytes: bytes} = data) do
    actions = for from <- :queue.to_list(bytes.read_into_requests), do: {:reply, from, :done}
    {%{data | bytes: clear(bytes)}, actions}
  end

  @doc false
  # ReadableByteStreamControllerError: the read-into requests reject. The
  # engine resets the queue, and rejects the read requests.
  def error(%{bytes: bytes} = data, reason) do
    actions =
      for from <- :queue.to_list(bytes.read_into_requests),
          do: {:reply, from, {:error, {:errored, reason}}}

    {%{data | bytes: clear(bytes)}, actions}
  end

  defp clear(bytes) do
    %{bytes | pull_intos: [], byob_request: nil, read_into_requests: :queue.new()}
  end

  @doc false
  # ReadableByteStreamControllerShouldCallPull, for a readable stream that
  # started.
  def should_pull?(data) do
    not data.bytes.close_requested and
      (not :queue.is_empty(data.read_requests) or
         not :queue.is_empty(data.bytes.read_into_requests) or
         data.readable_hwm - data.total_queued_size > 0)
  end

  @doc false
  # Tells whether a reader waits for bytes.
  def waiting?(%__MODULE__{read_into_requests: requests}), do: not :queue.is_empty(requests)
  def waiting?(nil), do: false

  # ---------------------------------------------------------------------------
  # The abstract operations
  # ---------------------------------------------------------------------------

  defp fill_read_request_from_queue(acc, from) do
    {{:value, {buffer, byte_offset, byte_length}}, queue} = :queue.out(field(acc, :queue))

    acc
    |> update_data(&%{&1 | queue: queue, total_queued_size: &1.total_queued_size - byte_length})
    |> handle_queue_drain()
    |> reply(from, {:ok, view(buffer, byte_offset, byte_length)})
  end

  defp process_read_requests_using_queue(acc) do
    if field(acc, :total_queued_size) > 0 and not :queue.is_empty(field(acc, :read_requests)) do
      {{:value, from}, requests} = :queue.out(field(acc, :read_requests))

      acc
      |> update_data(&%{&1 | read_requests: requests})
      |> fill_read_request_from_queue(from)
      |> process_read_requests_using_queue()
    else
      acc
    end
  end

  defp handle_queue_drain(acc) do
    if field(acc, :total_queued_size) == 0 and bytes(acc).close_requested,
      do: close_stream(acc),
      else: call_pull_if_needed(acc)
  end

  defp enqueue_chunk_to_queue(acc, buffer, byte_offset, byte_length) do
    update_data(acc, fn data ->
      %{
        data
        | queue: :queue.in({buffer, byte_offset, byte_length}, data.queue),
          total_queued_size: data.total_queued_size + byte_length
      }
    end)
  end

  defp enqueue_cloned_chunk_to_queue(acc, buffer, byte_offset, byte_length) do
    clone = ArrayBuffer.new(binary_part(buffer.data, byte_offset, byte_length))
    enqueue_chunk_to_queue(acc, clone, 0, byte_length)
  end

  defp enqueue_detached_pull_into_to_queue(acc, descriptor) do
    acc =
      if descriptor.bytes_filled > 0 do
        enqueue_cloned_chunk_to_queue(
          acc,
          descriptor.buffer,
          descriptor.byte_offset,
          descriptor.bytes_filled
        )
      else
        acc
      end

    acc |> shift_pending_pull_into() |> elem(1)
  end

  defp commit_filled_pull_intos(acc) do
    {acc, filled} = process_pull_into_descriptors_using_queue(acc)
    Enum.reduce(filled, acc, &commit_pull_into_descriptor(&2, &1, false))
  end

  defp process_pull_into_descriptors_using_queue(acc, filled \\ []) do
    case {pull_intos(acc), field(acc, :total_queued_size)} do
      {[descriptor | rest], size} when size > 0 ->
        {ready, descriptor, acc} = fill_pull_into_descriptor_from_queue(acc, descriptor)
        fill_next_pull_into(acc, ready, descriptor, rest, filled)

      _no_descriptor_or_no_bytes ->
        {acc, Enum.reverse(filled)}
    end
  end

  # A descriptor that has not its minimum bytes stays at the head.
  defp fill_next_pull_into(acc, true, descriptor, rest, filled) do
    acc = update_bytes(acc, &%{&1 | pull_intos: rest})
    process_pull_into_descriptors_using_queue(acc, [descriptor | filled])
  end

  defp fill_next_pull_into(acc, false, descriptor, rest, filled) do
    {update_bytes(acc, &%{&1 | pull_intos: [descriptor | rest]}), Enum.reverse(filled)}
  end

  # ReadableByteStreamControllerFillPullIntoDescriptorFromQueue. Returns
  # `{ready, descriptor, acc}`. The element size is 1, thus each byte is an
  # aligned byte.
  defp fill_pull_into_descriptor_from_queue(acc, descriptor) do
    max_bytes_to_copy =
      min(field(acc, :total_queued_size), descriptor.byte_length - descriptor.bytes_filled)

    ready = descriptor.bytes_filled + max_bytes_to_copy >= descriptor.minimum_fill
    {parts, queue} = take_from_queue(field(acc, :queue), max_bytes_to_copy, [])
    destination = descriptor.byte_offset + descriptor.bytes_filled
    buffer = ArrayBuffer.replace(descriptor.buffer, destination, IO.iodata_to_binary(parts))

    descriptor = %{
      descriptor
      | buffer: buffer,
        bytes_filled: descriptor.bytes_filled + max_bytes_to_copy
    }

    acc =
      update_data(
        acc,
        &%{&1 | queue: queue, total_queued_size: &1.total_queued_size - max_bytes_to_copy}
      )

    {ready, descriptor, acc}
  end

  defp take_from_queue(queue, 0, parts), do: {Enum.reverse(parts), queue}

  defp take_from_queue(queue, count, parts) do
    {{:value, {buffer, byte_offset, byte_length}}, rest} = :queue.out(queue)
    size = min(count, byte_length)
    part = binary_part(buffer.data, byte_offset, size)

    if size == byte_length do
      take_from_queue(rest, count - size, [part | parts])
    else
      entry = {buffer, byte_offset + size, byte_length - size}
      take_from_queue(:queue.in_r(entry, rest), count - size, [part | parts])
    end
  end

  # ReadableByteStreamControllerCommitPullIntoDescriptor. `done` is true
  # for a closed stream.
  defp commit_pull_into_descriptor(acc, descriptor, done) do
    filled_view = convert_pull_into_descriptor(descriptor)

    case descriptor.reader_type do
      :default -> fulfill_read_request(acc, filled_view, done)
      :byob -> fulfill_read_into_request(acc, filled_view, done)
    end
  end

  defp convert_pull_into_descriptor(descriptor) do
    view(transfer(descriptor.buffer), descriptor.byte_offset, descriptor.bytes_filled)
  end

  defp fulfill_read_request(acc, view, done) do
    {{:value, from}, requests} = :queue.out(field(acc, :read_requests))
    acc = update_data(acc, &%{&1 | read_requests: requests})
    reply(acc, from, if(done, do: :done, else: {:ok, view}))
  end

  defp fulfill_read_into_request(acc, view, done) do
    {{:value, from}, requests} = :queue.out(bytes(acc).read_into_requests)
    acc = update_bytes(acc, &%{&1 | read_into_requests: requests})
    reply(acc, from, if(done, do: {:done, view}, else: {:ok, view}))
  end

  defp invalidate_byob_request(acc), do: update_bytes(acc, &%{&1 | byob_request: nil})

  defp shift_pending_pull_into(acc) do
    [descriptor | rest] = pull_intos(acc)
    {descriptor, update_bytes(acc, &%{&1 | pull_intos: rest})}
  end

  defp append_pull_into(acc, descriptor) do
    update_bytes(acc, &%{&1 | pull_intos: &1.pull_intos ++ [descriptor]})
  end

  defp add_read_request(acc, from) do
    update_data(acc, &%{&1 | read_requests: :queue.in(from, &1.read_requests)})
  end

  defp add_read_into_request(acc, from) do
    update_bytes(acc, &%{&1 | read_into_requests: :queue.in(from, &1.read_into_requests)})
  end

  defp descriptor(buffer, byte_offset, byte_length, minimum_fill, reader_type) do
    %{
      buffer: buffer,
      buffer_byte_length: ArrayBuffer.byte_length(buffer),
      byte_offset: byte_offset,
      byte_length: byte_length,
      bytes_filled: 0,
      minimum_fill: minimum_fill,
      reader_type: reader_type
    }
  end

  # TransferArrayBuffer. The bytes of the struct move to a new buffer, and
  # all the copies of the first struct become detached.
  defp transfer(%ArrayBuffer{data: data} = buffer) do
    _detached = ArrayBuffer.detach(buffer)
    ArrayBuffer.new(data)
  end

  # A view of a buffer that the stream has. The stream does not examine the
  # bounds again.
  defp view(buffer, byte_offset, byte_length) do
    %Uint8Array{
      id: make_ref(),
      buffer: buffer,
      byte_offset: byte_offset,
      byte_length: byte_length
    }
  end

  # ---------------------------------------------------------------------------
  # The accumulator: `{data, actions, transition}`
  # ---------------------------------------------------------------------------

  defp start(data), do: {data, [], :none}

  defp finish({data, actions, transition}), do: {data, Enum.reverse(actions), transition}

  defp reply(acc, nil, _value), do: acc
  defp reply({data, actions, t}, from, value), do: {data, [{:reply, from, value} | actions], t}

  defp call_pull_if_needed({data, actions, t}) do
    {data, [{:next_event, :internal, :maybe_pull} | actions], t}
  end

  defp close_stream({data, actions, :none}), do: {data, actions, :close}

  defp error_stream({data, actions, _transition}, reason), do: {data, actions, {:error, reason}}

  defp update_data({data, actions, t}, fun), do: {fun.(data), actions, t}
  defp update_bytes(acc, fun), do: update_data(acc, &%{&1 | bytes: fun.(&1.bytes)})

  defp update_head(acc, fun) do
    update_bytes(acc, fn %{pull_intos: [first | rest]} = bytes ->
      %{bytes | pull_intos: [fun.(first) | rest]}
    end)
  end

  defp field({data, _actions, _t}, key), do: Map.fetch!(data, key)
  defp bytes({data, _actions, _t}), do: data.bytes
  defp pull_intos(acc), do: bytes(acc).pull_intos

  defp reader_type({data, _actions, _t}) do
    if is_pid(data.reader_pid), do: data.reader_mode
  end
end
