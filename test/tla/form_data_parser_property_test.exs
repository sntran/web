defmodule Web.TLA.FormDataParserPropertyTest do
  # Checks the properties of `tla/FormDataParser.tla` on the real parser of
  # `Web.FormData.parse/3`.
  #
  # The body has a file part and then a field, in random chunks. The source
  # can stall or have an error at a random chunk. A reader holds the file
  # stream. A random list of operations runs on the form: a get of the
  # field, an iteration, a freeze (an append), reads and a cancel of the file
  # stream, a cancel of the form, an abort of the signal, a stop of the
  # owner, and a kill of the parser. At the end, the reader reads the rest of
  # the file. The test cannot control each message between the processes,
  # thus it checks the properties of the specification in each run:
  #
  #   * NoCrash and NoLostReply: each call gets a value, a TypeError, or an
  #     exit with the reason of a failure, never an exit of OTP, and none
  #     waits with no end;
  #   * NoWrongError: a call gets an error only when the parse failed;
  #   * EntriesInOrder: the iteration gets the entries in the sequence of the
  #     body;
  #   * FileIntegrity: a file stream that ends has all the bytes of its part;
  #   * PromptStop and StreamEndsWithParser: a cancel, an abort, and a stop
  #     of the owner stop the parser, also when the source stalls, and the
  #     file stream is not readable after the stop.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.FormData.Parser
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultReader, as: Reader

  @moduletag capture_log: true

  @boundary "property-boundary"
  @answer_time 5_000

  defp operation do
    frequency([
      {3, constant(:get)},
      {2, constant(:iter)},
      {1, constant(:freeze)},
      {3, tuple({constant(:read), integer(1..3)})},
      {1, constant(:cancel_file)},
      {1, constant(:cancel)},
      {1, constant(:abort)},
      {1, constant(:owner_stop)},
      {1, constant(:kill)}
    ])
  end

  property "each call gets an answer, a file ends with all its bytes or an error, and a stop is prompt" do
    check all(
            file <- binary(max_length: 40),
            value <- string(:alphanumeric, max_length: 10),
            sizes <- list_of(integer(1..12), max_length: 12),
            source_end <-
              one_of([constant(:none), tuple({member_of([:stall, :error]), integer(1..8)})]),
            operations <- list_of(operation(), max_length: 6),
            max_runs: 80
          ) do
      run = start(file, value, sizes, source_end)

      try do
        run = Enum.reduce(operations, run, &operate/2)
        run = finish(run)
        check_properties(run, file, value)
      after
        Process.demonitor(run.parser_monitor, [:flush])
        for pid <- [run.owner, run.reader, run.queue], is_pid(pid), do: Process.exit(pid, :kill)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The run
  # ---------------------------------------------------------------------------

  defp payload(file, value) do
    "--#{@boundary}\r\n" <>
      ~s(Content-Disposition: form-data; name="upload"; filename="f.bin"\r\n) <>
      "Content-Type: application/octet-stream\r\n\r\n" <>
      file <>
      "\r\n--#{@boundary}\r\n" <>
      ~s(Content-Disposition: form-data; name="after"\r\n\r\n) <>
      value <> "\r\n--#{@boundary}--\r\n"
  end

  # The first chunk has the headers of the file part: the parse finds the
  # first entry with it. The other chunks have the random sizes.
  defp chunks(body, sizes) do
    {header_end, 4} = :binary.match(body, "\r\n\r\n")
    {first, rest} = :erlang.split_binary(body, header_end + 4)
    [first | split(rest, sizes)]
  end

  defp split("", _sizes), do: []
  defp split(rest, []), do: [rest]

  defp split(rest, [size | _sizes]) when size >= byte_size(rest), do: [rest]

  defp split(rest, [size | sizes]) do
    {chunk, rest} = :erlang.split_binary(rest, size)
    [chunk | split(rest, sizes)]
  end

  # A source that gives each chunk at a pull, only for a read of the parser
  # (the high water mark 0). At the chunk `at`, it stalls (it gives nothing
  # more), or it has an error.
  defp source(queue, source_end) do
    ReadableStream.new(
      %{
        pull: fn controller ->
          step =
            Agent.get_and_update(queue, fn {chunks, index} ->
              {{chunks, index}, {Enum.drop(chunks, 1), index + 1}}
            end)

          case {step, source_end} do
            {{_chunks, index}, {:stall, at}} when index >= at ->
              :ok

            {{_chunks, index}, {:error, at}} when index >= at ->
              error(controller, :source_failure)

            {{[], _index}, _end} ->
              Web.ReadableStreamDefaultController.close(controller)

            {{[chunk | _rest], _index}, _end} ->
              enqueue(controller, chunk)
          end
        end
      },
      high_water_mark: 0
    )
  end

  defp error(controller, reason),
    do: Web.ReadableStreamDefaultController.error(controller, reason)

  defp enqueue(controller, chunk),
    do: Web.ReadableStreamDefaultController.enqueue(controller, chunk)

  defp start(file, value, sizes, source_end) do
    owner = spawn(fn -> receive(do: (:never -> :ok)) end)
    controller = Web.AbortController.new()
    {:ok, queue} = Agent.start(fn -> {chunks(payload(file, value), sizes), 0} end)
    stream = source(queue, source_end)

    form = Web.FormData.parse(stream, @boundary, signal: controller.signal, owner: owner)

    run = %{
      form: form,
      parser: form.coordinator,
      parser_monitor: Process.monitor(form.coordinator),
      file_stream: nil,
      reader: nil,
      owner: owner,
      controller: controller,
      queue: queue,
      source_end: source_end,
      calls: [],
      stops: [],
      froze: false,
      file_canceled: false
    }

    # The file stream pulls a piece when it starts: the source can stall or
    # fail before the parser answers the get of the file. Then the get is a
    # call that waits, as the other calls.
    run = call(run, :upload, fn -> Web.FormData.get(form, "upload") end)
    [{:upload, ref, _pid, _before_freeze?}] = run.calls

    case await_upload(run, ref) do
      {:ok, %Web.File{stream: file_stream}} ->
        case reader(file_stream) do
          nil -> %{run | calls: [], file_canceled: true}
          reader -> %{run | calls: [], file_stream: file_stream.controller_pid, reader: reader}
        end

      # The check of the properties gets the result again.
      {:answer, result} ->
        send(self(), {ref, result})
        %{run | file_canceled: true}

      :stalled ->
        %{run | file_canceled: true}
    end
  end

  # The answer of the get of the file, or `:stalled` when the parser waits
  # for a source that stalled.
  defp await_upload(run, ref, attempts \\ 5_000) do
    receive do
      {^ref, {:ok, file}} -> {:ok, file}
      {^ref, result} -> {:answer, result}
    after
      1 ->
        cond do
          stalled?(run) and at_rest?(run.parser) -> :stalled
          attempts == 0 -> flunk("the get of the file got no answer")
          true -> await_upload(run, ref, attempts - 1)
        end
    end
  end

  defp stalled?(%{source_end: {:stall, at}, queue: queue}),
    do: Agent.get(queue, &elem(&1, 1)) > at

  defp stalled?(_run), do: false

  # The reader has the lock of the file stream before the operations. A
  # source that failed can end the file stream before the reader takes the
  # lock: the run then has no reader.
  defp reader(file_stream) do
    test = self()

    reader =
      spawn(fn ->
        try do
          ReadableStream.get_reader(file_stream)
        rescue
          Web.TypeError -> send(test, {:reader, self(), :gone})
        else
          reader ->
            send(test, {:reader, self(), :ok})
            reader_loop(test, reader, [])
        end
      end)

    assert_receive {:reader, ^reader, lock}
    if lock == :ok, do: reader
  end

  # The reader of the file stream reads on command, and tells its result at
  # the end of the stream.
  defp reader_loop(test, reader, bytes) do
    receive do
      {:read, count} -> reader_reads(test, reader, bytes, count)
      :read_all -> reader_reads(test, reader, bytes, :all)
      :cancel -> send(test, {:file_result, :canceled, await_cancel(reader)})
    end
  end

  defp reader_reads(test, reader, bytes, 0), do: reader_loop(test, reader, bytes)

  defp reader_reads(test, reader, bytes, count) do
    case read(reader) do
      {:ok, chunk} ->
        count = if count == :all, do: :all, else: count - 1
        reader_reads(test, reader, [bytes | [Web.Uint8Array.to_binary(chunk)]], count)

      :done ->
        send(test, {:file_result, :done, IO.iodata_to_binary(bytes)})

      {:error, reason} ->
        send(test, {:file_result, :error, reason})
    end
  end

  defp read(reader) do
    case await(Reader.read(reader)) do
      %{done: true} -> :done
      %{value: chunk} -> {:ok, chunk}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp await_cancel(reader) do
    await(Reader.cancel(reader, :reader_cancel))
  catch
    :exit, reason -> reason
  end

  # ---------------------------------------------------------------------------
  # The operations
  # ---------------------------------------------------------------------------

  defp operate(:get, run), do: call(run, :get, fn -> Web.FormData.get(run.form, "after") end)
  defp operate(:iter, run), do: call(run, :iter, fn -> Enum.to_list(run.form) end)

  defp operate(:freeze, run) do
    run = call(run, :freeze, fn -> Web.FormData.append(run.form, "added", "x") end)
    %{run | froze: true}
  end

  defp operate({:read, _count}, %{file_canceled: true} = run), do: run

  defp operate({:read, count}, run) do
    send(run.reader, {:read, count})
    settle(run)
  end

  defp operate(:cancel_file, %{file_canceled: true} = run), do: run

  defp operate(:cancel_file, run) do
    send(run.reader, :cancel)
    settle(%{run | file_canceled: true})
  end

  defp operate(:cancel, run) do
    stop(run, :cancel, fn ->
      call(run, :cancel, fn -> Parser.cancel(run.form.coordinator, :form_cancel) end)
    end)
  end

  defp operate(:abort, run) do
    stop(run, :abort, fn ->
      Web.AbortController.abort(run.controller, :signal_abort)
      settle(run)
    end)
  end

  defp operate(:owner_stop, run) do
    stop(run, :owner, fn ->
      Process.exit(run.owner, :kill)
      settle(run)
    end)
  end

  defp operate(:kill, run) do
    Process.exit(run.parser, :kill)
    settle(%{run | stops: [:kill | run.stops]})
  end

  # A stop with the terminate of the parser. StreamEndsWithParser: when the
  # parser stops, the file stream is not readable, also when no pull comes.
  defp stop(run, kind, fun) do
    alive? = Process.alive?(run.parser) and :kill not in run.stops
    run = fun.()

    if alive? and is_pid(run.file_stream) do
      assert_receive {:DOWN, ref, :process, _pid, _reason}
                     when ref == run.parser_monitor,
                     @answer_time

      wait_until(fn -> not readable?(run.file_stream) end)
      refute readable?(run.file_stream), "the file stream stays after the stop of the parser"
    end

    %{run | stops: [kind | run.stops]}
  end

  # Each call runs in a process of its own, and gives its result: a value, a
  # raise, or an exit.
  defp call(run, kind, fun) do
    test = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        result =
          try do
            {:ok, fun.()}
          rescue
            error -> {:raise, error}
          catch
            :exit, reason -> {:exit, reason}
          end

        send(test, {ref, result})
      end)

    settle(%{run | calls: [{kind, ref, pid, not run.froze} | run.calls]})
  end

  # The processes of the run wait, or stopped: the parser has the messages
  # that the operation sent. A process that waits for a message that is not
  # in its mailbox, such as a parser that waits for a source that stalls,
  # is at rest.
  defp settle(run) do
    pids = [run.parser, run.reader | Enum.map(run.calls, &elem(&1, 2))]
    wait_until(fn -> pids |> Enum.filter(&is_pid/1) |> Enum.all?(&at_rest?/1) end)
    run
  end

  defp at_rest?(pid) do
    case Process.info(pid, :status) do
      nil -> true
      {:status, :waiting} -> true
      _other -> false
    end
  end

  defp wait_until(fun, attempts \\ 500) do
    cond do
      fun.() -> :ok
      attempts == 0 -> :ok
      true -> Process.sleep(1) && wait_until(fun, attempts - 1)
    end
  end

  # The reader reads the rest of the file. A source that stalls with no stop
  # keeps a call: the test then cancels the form.
  defp finish(run) do
    run =
      if match?({:stall, _at}, run.source_end) and run.stops == [] do
        operate(:cancel, run)
      else
        run
      end

    if not run.file_canceled, do: send(run.reader, :read_all)
    run
  end

  # ---------------------------------------------------------------------------
  # The properties
  # ---------------------------------------------------------------------------

  defp check_properties(run, file, value) do
    results =
      for {kind, ref, _pid, before_freeze?} <- run.calls do
        assert_receive {^ref, result}, @answer_time, "the call #{kind} got no answer"
        {kind, result, before_freeze?}
      end

    {file_kind, file_result} = file_result(run)
    stopped? = stopped?(run, Enum.any?(run.stops, &(&1 in [:cancel, :abort, :owner, :kill])))
    Enum.each(results, &check_call(&1, run, value))

    # FileIntegrity: an end of the stream comes only with all the bytes.
    if file_kind == :done, do: assert(file_result == file)

    # PromptStop: a cancel, an abort, and a stop of the owner stop the
    # parser, also when the source stalls.
    if Enum.any?(run.stops, &(&1 in [:cancel, :abort, :owner])), do: assert(stopped?)

    # StreamEndsWithParser: after a stop with its terminate, the file stream
    # is not readable.
    if stopped? and :kill not in run.stops and is_pid(run.file_stream) do
      wait_until(fn -> not readable?(run.file_stream) end)
      refute readable?(run.file_stream)
    end
  end

  defp check_call({kind, result, before_freeze?}, run, value) do
    refute otp_exit?(result), "the call #{kind} got an exit of OTP: #{inspect(result)}"

    if run.stops == [] and no_source_error?(run),
      do: assert_no_error(kind, result, before_freeze?)

    assert_answer(kind, result, value)
  end

  # A run with no file stream has no reader.
  defp file_result(%{reader: nil}), do: {:none, nil}

  defp file_result(_run) do
    assert_receive {:file_result, kind, result}, @answer_time, "the file reader waits"
    {kind, result}
  end

  # A parser that must stop gets the time of an answer. Each other parser
  # stopped already, or it stays.
  defp stopped?(run, must_stop?) do
    time = if must_stop?, do: @answer_time, else: 0

    not Process.alive?(run.parser) or
      receive do
        {:DOWN, ref, :process, _pid, _reason} when ref == run.parser_monitor -> true
      after
        time -> not Process.alive?(run.parser)
      end
  end

  defp no_source_error?(run), do: not match?({:error, _at}, run.source_end)

  defp readable?(pid) do
    match?(%{state: :readable}, Web.Stream.call(pid, :get_slots, nil))
  end

  # An exit of OTP: a call that the library did not answer.
  defp otp_exit?({:exit, {_reason, {:gen_statem, :call, _args}}}), do: true
  defp otp_exit?({:exit, {:noproc, _}}), do: true
  defp otp_exit?(_result), do: false

  # NoWrongError: with no stop and no error of the source, a call gets its
  # value. A call after a freeze can get a TypeError: the form is static. A
  # get before the freeze is in the parser when the freeze comes: the parse
  # is then complete, and the get gets its value. An iteration makes a call
  # for each entry, thus its calls can come after the freeze.
  defp assert_no_error(_kind, {:ok, _value}, _before_freeze?), do: :ok

  defp assert_no_error(kind, {:raise, %Web.TypeError{message: message}}, before_freeze?) do
    assert message =~ "not available", "the call #{kind} got the error #{message}"
    refute kind in [:get, :upload] and before_freeze?, "the get before the freeze has no value"
  end

  defp assert_no_error(kind, result, _before_freeze?),
    do: flunk("the call #{kind} got #{inspect(result)}")

  # The answers of the calls that got a value.
  defp assert_answer(:get, {:ok, answer}, value), do: assert(answer == value)

  # EntriesInOrder: the iteration gets the entries in the sequence of the
  # body.
  defp assert_answer(:iter, {:ok, entries}, value) do
    assert [["upload", %Web.File{}], ["after", ^value]] = entries
  end

  defp assert_answer(:freeze, {:ok, form}, value) do
    assert [{"upload", %Web.File{}}, {"after", ^value}, {"added", "x"}] = form.entries
  end

  defp assert_answer(_kind, _result, _value), do: :ok
end
