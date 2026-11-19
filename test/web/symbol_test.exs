defmodule Web.SymbolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Web

  doctest Web.Symbol

  alias Web.DOMException
  alias Web.SuppressedError
  alias Web.TestSupport.Disposable

  defp dispose(resource), do: Web.Symbol.Protocol.symbol(resource, Symbol.dispose(), [])

  # ---------------------------------------------------------------------------
  # The symbols and the protocol
  # ---------------------------------------------------------------------------

  describe "the symbols" do
    test "are atoms" do
      assert Symbol.dispose() == :dispose
      assert Symbol.async_dispose() == :async_dispose
      assert Symbol.iterator() == :iterator
      assert Symbol.async_iterator() == :async_iterator
    end

    test "a value with no implementation is not disposable" do
      for value <- [5, "text", :atom, %{}, [], {1, 2}, self(), %URI{}] do
        refute Symbol.disposable?(value)
        assert Web.Symbol.Protocol.symbol(value, :dispose, []) == :unsupported
      end
    end
  end

  describe "the disposal of" do
    test "a broadcast channel closes it" do
      channel = BroadcastChannel.new("symbol-#{System.unique_integer([:positive])}")
      assert Symbol.disposable?(channel)

      assert :ok = dispose(channel)

      exception = assert_raise DOMException, fn -> BroadcastChannel.post_message(channel, 1) end
      assert exception.name == "InvalidStateError"

      # A resource that is released already is accepted.
      assert :ok = dispose(channel)
      assert :ok = Web.Symbol.Protocol.symbol(channel, :async_dispose, [])
      assert :unsupported = Web.Symbol.Protocol.symbol(channel, :iterator, [])
    end

    test "a message port closes it" do
      {port1, port2} = MessageChannel.new()
      test = self()
      MessagePort.onclose(port2, fn -> send(test, :closed) end)

      assert :ok = dispose(port1)
      assert_receive :closed
      assert :ok = dispose(port1)
      assert :ok = dispose(port2)
    end

    test "a port of Erlang closes it" do
      port = Port.open({:spawn, "cat"}, [:binary])
      assert Symbol.disposable?(port)

      assert :ok = dispose(port)
      assert Port.info(port) == nil

      # A port that is closed, and a port of a different process, are
      # accepted.
      assert :ok = dispose(port)
      assert :ok = Web.Symbol.Protocol.symbol(port, :async_dispose, [])
      assert :unsupported = Web.Symbol.Protocol.symbol(port, :iterator, [])
    end

    test "a reader releases its lock" do
      stream = ReadableStream.from(["a", "b"])
      reader = ReadableStream.get_reader(stream)
      assert ReadableStream.locked?(stream)

      assert :ok = dispose(reader)
      refute ReadableStream.locked?(stream)
      assert :unsupported = Web.Symbol.Protocol.symbol(reader, :iterator, [])
      ReadableStream.cancel(stream)
    end

    test "a BYOB reader releases its lock" do
      stream = ReadableStream.new(%{type: "bytes", pull: fn _controller -> :ok end})
      reader = ReadableStream.get_reader(stream, mode: "byob")
      assert %ReadableStreamBYOBReader{} = reader

      assert :ok = Web.Symbol.Protocol.symbol(reader, :async_dispose, [])
      refute ReadableStream.locked?(stream)
      ReadableStream.cancel(stream)
    end

    test "a writer releases its lock" do
      stream = WritableStream.new()
      writer = WritableStream.get_writer(stream)
      assert WritableStream.locked?(stream)

      assert :ok = dispose(writer)
      refute WritableStream.locked?(stream)
      assert :unsupported = Web.Symbol.Protocol.symbol(writer, :iterator, [])
    end

    test "a socket closes it" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listener)
      socket = Web.connect("127.0.0.1:#{port}")
      {:ok, _accepted} = :gen_tcp.accept(listener, 1_000)
      assert Symbol.disposable?(socket)

      result =
        using socket do
          :used
        end

      assert result == :used
      assert Web.Promise.await(socket.closed) != nil
      assert :unsupported = Web.Symbol.Protocol.symbol(socket, :iterator, [])
      :gen_tcp.close(listener)
    end
  end

  # ---------------------------------------------------------------------------
  # The macro using
  # ---------------------------------------------------------------------------

  describe "using" do
    test "with <- gives the resource to the block, and releases it after" do
      result =
        using resource <- Disposable.new(:a) do
          refute_received {:disposed, :a, _symbol}
          {:block, resource.name}
        end

      assert result == {:block, :a}
      assert_received {:disposed, :a, :dispose}
    end

    test "with = and with no name" do
      resource = Disposable.new(:a)

      assert :ok ==
               (using same = resource do
                  assert same == resource
                  :ok
                end)

      assert_received {:disposed, :a, :dispose}

      assert :no_name == Web.using(Disposable.new(:b), do: :no_name)
      assert_received {:disposed, :b, :dispose}
    end

    test "a nil value has no disposal, and the block runs" do
      result =
        using resource <- nil do
          {:block, resource}
        end

      assert result == {:block, nil}
    end

    test "a value that is not disposable raises TypeError before the block" do
      test = self()

      assert_raise Web.TypeError, "The value is not disposable: 5", fn ->
        using _value <- 5 do
          send(test, :block)
        end
      end

      refute_received :block
    end

    test "a value with no function of disposal raises TypeError after the block" do
      assert_raise Web.TypeError, ~r/is not disposable/, fn ->
        using Disposable.new(:a, :unsupported) do
          :block
        end
      end
    end

    test "a disposal that returns a promise is awaited" do
      assert :block == Web.using(Disposable.new(:a, :promise), do: :block)
      assert_received {:disposed, :a, :dispose}
    end

    test "a resource with only async_dispose uses it" do
      assert :block == Web.using(Disposable.new(:a, :async_only), do: :block)
      assert_received {:disposed, :a, :async_dispose}
    end

    test "the resource is released when the block raises, throws, or exits" do
      assert_raise RuntimeError, "block", fn ->
        using Disposable.new(:a) do
          raise "block"
        end
      end

      assert_received {:disposed, :a, :dispose}

      assert catch_throw(Web.using(Disposable.new(:b), do: throw(:block))) == :block
      assert_received {:disposed, :b, :dispose}

      assert catch_exit(Web.using(Disposable.new(:c), do: exit(:block))) == :block
      assert_received {:disposed, :c, :dispose}
    end

    test "the error of the block keeps its stacktrace" do
      using Disposable.new(:a) do
        raise "block"
      end
    rescue
      RuntimeError ->
        assert Enum.any?(__STACKTRACE__, fn {module, _function, _arity, _location} ->
                 module == __MODULE__
               end)
    end

    test "the resource is released when the pattern does not match" do
      assert_raise MatchError, fn ->
        using %{name: :other} <- Disposable.new(:a) do
          :block
        end
      end

      assert_received {:disposed, :a, :dispose}
    end

    test "the error of a disposal is raised" do
      assert_raise RuntimeError, "the disposal of a failed", fn ->
        Web.using(Disposable.new(:a, :raise), do: :block)
      end

      assert catch_throw(Web.using(Disposable.new(:b, :throw), do: :block)) == {:disposal, :b}
      assert catch_exit(Web.using(Disposable.new(:c, :exit), do: :block)) == {:disposal, :c}
      assert catch_exit(Web.using(Disposable.new(:d, :rejected), do: :block)) == {:disposal, :d}
    end

    test "the error of the block and the error of the disposal are in a SuppressedError" do
      exception =
        assert_raise SuppressedError, "An error was suppressed during disposal.", fn ->
          using Disposable.new(:a, :raise) do
            raise ArgumentError, "block"
          end
        end

      assert %RuntimeError{message: "the disposal of a failed"} = exception.error
      assert %ArgumentError{message: "block"} = exception.suppressed

      # A value of a throw and a reason of an exit are kept as they are.
      exception =
        assert_raise SuppressedError, fn ->
          Web.using(Disposable.new(:b, :throw), do: exit(:block))
        end

      assert exception.error == {:disposal, :b}
      assert exception.suppressed == :block
    end

    test "resources in more than one using are released in the opposite sequence" do
      using Disposable.new(:outer) do
        using Disposable.new(:middle) do
          using Disposable.new(:inner) do
            :block
          end
        end
      end

      assert_received {:disposed, :inner, :dispose}
      assert_received {:disposed, :middle, :dispose}
      assert_received {:disposed, :outer, :dispose}
      assert {:messages, []} = Process.info(self(), :messages)
    end

    test "each failed disposal adds a SuppressedError" do
      exception =
        assert_raise SuppressedError, fn ->
          using Disposable.new(:outer, :raise) do
            using Disposable.new(:inner, :raise) do
              raise "block"
            end
          end
        end

      assert %RuntimeError{message: "the disposal of outer failed"} = exception.error
      assert %SuppressedError{error: inner, suppressed: block} = exception.suppressed
      assert %RuntimeError{message: "the disposal of inner failed"} = inner
      assert %RuntimeError{message: "block"} = block
    end

    test "a broadcast channel is closed at the end of the block" do
      channel =
        using channel <- BroadcastChannel.new("using-#{System.unique_integer([:positive])}") do
          assert :ok = BroadcastChannel.post_message(channel, %{status: "started"})
          channel
        end

      assert_raise DOMException, "The BroadcastChannel is closed.", fn ->
        BroadcastChannel.post_message(channel, "after")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  describe "properties" do
    property "each resource is released one time, in the opposite sequence" do
      check all(
              modes <- list_of(member_of([:ok, :promise, :async_only, :raise]), max_length: 6),
              block_fails <- boolean(),
              max_runs: 200
            ) do
        resources = modes |> Enum.with_index() |> Enum.map(fn {mode, name} -> {name, mode} end)
        outcome = run_nested(resources, block_fails)

        released =
          for _resource <- resources do
            assert_received {:disposed, name, _symbol}
            name
          end

        assert released == resources |> Enum.map(&elem(&1, 0)) |> Enum.reverse()
        refute_received {:disposed, _name, _symbol}

        # No error is lost: the result has one error for the block, and one
        # for each disposal that failed, from the outer one to the inner one.
        failed = for {name, :raise} <- resources, do: "the disposal of #{name} failed"
        block = if block_fails, do: ["block"], else: []
        assert errors(outcome) == failed ++ block
      end
    end
  end

  defp run_nested(resources, block_fails) do
    {:ok, nest(resources, block_fails)}
  rescue
    exception -> {:error, exception}
  end

  defp nest([], true), do: raise("block")
  defp nest([], false), do: :block

  defp nest([{name, mode} | rest], block_fails) do
    using Disposable.new(name, mode) do
      nest(rest, block_fails)
    end
  end

  # The messages of the errors of a result, from the last one to the first.
  defp errors({:ok, :block}), do: []
  defp errors({:error, exception}), do: errors(exception)

  defp errors(%SuppressedError{error: error, suppressed: suppressed}) do
    errors(error) ++ errors(suppressed)
  end

  defp errors(%RuntimeError{message: message}), do: [message]
end
