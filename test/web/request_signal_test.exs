defmodule Web.RequestSignalTest do
  # The signal of a `Web.Request`, as the `Request` constructor and
  # `clone()` of the Fetch Standard make it: a new signal that depends on a
  # source signal, with no process until an operation needs one. See
  # "The signal of a request" in `Web.AbortSignal`, and
  # `tla/LazySignal.tla`.
  use ExUnit.Case, async: true

  import Web, only: [await: 1]

  alias Web.AbortController
  alias Web.AbortSignal
  alias Web.Event
  alias Web.EventTarget
  alias Web.Request

  @url "https://example.com/"

  # The live process of a lazy signal, with no start.
  defp process_of(signal), do: AbortSignal.__listener_pid__(signal)

  defp dependents(signal), do: :sys.get_state(signal.pid).dependents

  defp assert_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
  end

  # A process that keeps a copy of the struct, and runs a function for the
  # test on each request.
  defp copy do
    spawn_link(fn -> copy_loop() end)
  end

  defp copy_loop do
    receive do
      {:run, from, fun} ->
        send(from, {:ran, self(), fun.()})
        copy_loop()
    end
  end

  defp run(copy, fun) do
    send(copy, {:run, self(), fun})
    assert_receive {:ran, ^copy, result}
    result
  end

  defp recorder(name) do
    test = self()
    fn event -> send(test, {name, event}) end
  end

  describe "the constructor" do
    test "gives a request with no signal a signal that no abort can reach, with no process" do
      request = Request.new(@url)
      signal = request.signal

      assert %AbortSignal{pid: nil, lazy: {_sequence, nil}} = signal
      assert signal != Request.new(@url).signal
      refute AbortSignal.aborted?(signal)
      assert AbortSignal.reason(signal) == nil
      assert AbortSignal.throw_if_aborted(signal) == :ok
      assert AbortSignal.onabort(signal) == nil
      assert AbortSignal.check!(signal) == :ok
      assert process_of(signal) == nil

      # A subscription never gets an abort.
      assert {:ok, subscription} = AbortSignal.subscribe(signal)
      assert AbortSignal.receive_abort(subscription, 0, true) == :ok
      assert AbortSignal.unsubscribe(subscription) == :ok
    end

    test "gives a new signal that depends on the option :signal, with no process" do
      controller = AbortController.new()
      request = Request.new(@url, signal: controller.signal)
      signal = request.signal

      assert signal != controller.signal
      assert %AbortSignal{pid: nil, lazy: {_sequence, source}} = signal
      assert source == controller.signal

      refute AbortSignal.aborted?(signal)
      assert AbortSignal.reason(signal) == nil
      assert AbortSignal.throw_if_aborted(signal) == :ok
      assert AbortSignal.onabort(signal) == nil

      # The constructor and the reads start no process, and leave no
      # subscription and no dependent signal at the source.
      assert process_of(signal) == nil
      assert dependents(controller.signal) == []
      assert :sys.get_state(controller.signal.pid).subscribers == %{}

      :ok = AbortController.abort(controller, :why)
      assert AbortSignal.aborted?(signal)
      assert AbortSignal.reason(signal) == :why
      assert catch_error(AbortSignal.throw_if_aborted(signal)) == :why
      assert process_of(signal) == nil
    end

    test "gives a new aborted signal for an aborted signal" do
      given = AbortSignal.abort(:early)
      signal = Request.new(@url, signal: given).signal

      assert %AbortSignal{aborted: true, reason: :early, pid: nil, lazy: nil} = signal
      assert signal.ref != given.ref

      # A signal with a process that aborted is aborted with its reason.
      controller = AbortController.new()
      :ok = AbortController.abort(controller, :before)
      signal = Request.new(@url, signal: controller.signal).signal
      assert AbortSignal.aborted?(signal)
      assert AbortSignal.reason(signal) == :before
    end

    test "gives a request from a request a signal that depends on the signal of the input" do
      first = AbortController.new()
      second = AbortController.new()

      # A request with a body gives its body to the new request: each case
      # has a new input.
      for body <- [nil, "body"],
          {init, source} <- [
            {[], first.signal},
            {[signal: nil], first.signal},
            {[method: "PUT"], first.signal},
            {[signal: second.signal], second.signal}
          ] do
        method = if body, do: "POST", else: "GET"
        input = Request.new(@url, method: method, body: body, signal: first.signal)
        request = Request.new(input, init)

        assert request.signal != input.signal
        assert AbortSignal.__source__(request.signal) == source
        assert request.options[:signal] == request.signal
      end
    end

    test "gives the source of a signal" do
      controller = AbortController.new()
      assert AbortSignal.__source__(controller.signal) == controller.signal
      assert AbortSignal.__source__(nil) == nil

      # A subscription goes to the process of the source.
      signal = Request.new(@url, signal: controller.signal).signal
      assert {:ok, %{pid: pid} = subscription} = AbortSignal.subscribe(signal)
      assert pid == controller.signal.pid
      :ok = AbortController.abort(controller, :why)
      assert AbortSignal.receive_abort(subscription, 1_000, true) == {:error, :aborted, :why}
      AbortSignal.unsubscribe(subscription)
    end

    test "gives a request of a URL the ambient signal as the source" do
      controller = AbortController.new()

      request =
        Web.AsyncContext.with_signal(controller.signal, fn -> Request.new(@url) end)

      assert AbortSignal.__source__(request.signal) == controller.signal
    end
  end

  describe "clone/1" do
    test "gives the clone a new signal that depends on the signal of the request" do
      controller = AbortController.new()

      for body <- [nil, "body"] do
        method = if body, do: "POST", else: "GET"
        request = Request.new(@url, method: method, body: body, signal: controller.signal)
        {original, clone} = Request.clone(request)

        assert original.signal == request.signal
        assert clone.signal != request.signal
        assert AbortSignal.__source__(clone.signal) == controller.signal
        assert clone.options[:signal] == clone.signal

        # The clone of a clone depends on the same source.
        {_clone, second} = Request.clone(clone)
        assert AbortSignal.__source__(second.signal) == controller.signal
      end

      :ok = AbortController.abort(controller, :why)
      request = Request.new(@url, signal: controller.signal)
      {_original, clone} = Request.clone(request)
      assert AbortSignal.reason(clone.signal) == :why
    end

    test "gives a response no signal" do
      response = Web.Response.new("body")
      {original, clone} = Web.Response.clone(response)
      refute Map.has_key?(original, :signal) or Map.has_key?(clone, :signal)
    end
  end

  describe "a listener" do
    test "starts one process, and runs at the abort of the source with the request as target" do
      controller = AbortController.new()
      request = Request.new(@url, signal: controller.signal)
      signal = request.signal

      assert EventTarget.add_event_listener(signal, "abort", recorder(:abort)) == signal
      pid = process_of(signal)
      assert is_pid(pid)
      assert [%AbortSignal{pid: ^pid}] = dependents(controller.signal)
      assert :sys.get_state(pid).keepers == %{}

      :ok = AbortController.abort(controller, :why)
      assert_received {:abort, %Event{type: "abort", is_trusted: true} = event}
      assert event.target == signal
      assert event.current_target == signal

      # The process stops after the event.
      assert_down(pid)
      assert process_of(signal) == nil
    end

    test "of a signal that no abort can reach runs only for a dispatch" do
      signal = Request.new(@url).signal
      EventTarget.add_event_listener(signal, "abort", recorder(:abort))
      pid = process_of(signal)
      assert :sys.get_state(pid).sources == []

      assert {^signal, true} = EventTarget.dispatch_event(signal, Event.new("abort"))
      assert_received {:abort, %Event{is_trusted: false, target: ^signal}}
      refute AbortSignal.aborted?(signal)
    end

    test "of each copy uses the same process, and runs at the abort" do
      controller = AbortController.new()
      signal = Request.new(@url, signal: controller.signal).signal
      copies = for _index <- 1..4, do: copy()
      test = self()

      # The copies start at the same time.
      for {copy, index} <- Enum.with_index(copies) do
        send(
          copy,
          {:run, test,
           fn ->
             receive do
               :go -> :ok
             end

             EventTarget.add_event_listener(signal, "abort", fn -> send(test, {:fired, index}) end)

             process_of(signal)
           end}
        )
      end

      Enum.each(copies, &send(&1, :go))

      pids =
        for copy <- copies do
          assert_receive {:ran, ^copy, pid}
          pid
        end

      assert [pid] = Enum.uniq(pids)
      assert [%AbortSignal{pid: ^pid}] = dependents(controller.signal)

      :ok = AbortController.abort(controller, :why)
      for index <- 0..3, do: assert_received({:fired, ^index})
    end

    test "fires in the sequence in which the signals were made" do
      controller = AbortController.new()
      request = Request.new(@url, signal: controller.signal)
      {_original, clone} = Request.clone(request)
      any = AbortSignal.any([controller.signal])

      # The processes start in the reverse sequence.
      EventTarget.add_event_listener(any, "abort", recorder(:any))
      EventTarget.add_event_listener(clone.signal, "abort", recorder(:clone))
      EventTarget.add_event_listener(request.signal, "abort", recorder(:request))

      :ok = AbortController.abort(controller)
      {:messages, messages} = Process.info(self(), :messages)
      assert [{:request, _first}, {:clone, _second}, {:any, _third}] = messages
    end
  end

  describe "the other operations of an event target" do
    test "a remove and a dispatch start no process, and use the process of the listeners" do
      controller = AbortController.new()
      signal = Request.new(@url, signal: controller.signal).signal
      listener = recorder(:listener)

      assert EventTarget.remove_event_listener(signal, "abort", listener) == signal
      assert Web.EventTarget.Protocol.remove_event_listener(signal, "abort", listener) == signal
      assert {^signal, true} = EventTarget.dispatch_event(signal, Event.new("abort"))
      assert process_of(signal) == nil

      # A copy in a different process adds the listener, and a copy in this
      # process dispatches and removes it.
      copy = copy()
      run(copy, fn -> EventTarget.add_event_listener(signal, "x", listener, capture: true) end)
      assert {^signal, true} = EventTarget.dispatch_event(signal, Event.new("x"))
      assert_received {:listener, %Event{type: "x", is_trusted: false, target: ^signal}}

      assert EventTarget.remove_event_listener(signal, "x", listener) == signal
      assert {^signal, true} = EventTarget.dispatch_event(signal, Event.new("x"))
      assert_received {:listener, _event}

      assert EventTarget.remove_event_listener(signal, "x", listener, capture: true) == signal
      assert {^signal, true} = EventTarget.dispatch_event(signal, Event.new("x"))
      refute_received {:listener, _event}

      run(copy, fn -> EventTarget.add_event_listener(signal, "y", listener) end)
      assert Web.EventTarget.Protocol.remove_event_listener(signal, "y", listener) == signal
      assert {^signal, true} = EventTarget.dispatch_event(signal, Event.new("y"))
      refute_received {:listener, _event}
    end

    test "onabort/2 sets the event handler for each copy" do
      controller = AbortController.new()
      signal = Request.new(@url, signal: controller.signal).signal
      handler = recorder(:handler)

      # The value nil with no process starts no process.
      assert AbortSignal.onabort(signal, nil) == signal
      assert process_of(signal) == nil

      copy = copy()
      assert run(copy, fn -> AbortSignal.onabort(signal, handler) end) == signal
      assert AbortSignal.onabort(signal) == handler
      assert AbortSignal.onabort(signal, nil) == signal
      assert run(copy, fn -> AbortSignal.onabort(signal) end) == nil

      assert AbortSignal.onabort(signal, handler) == signal
      :ok = AbortController.abort(controller, :why)
      assert_received {:handler, %Event{type: "abort", target: ^signal}}
    end

    test "the option :signal of a listener of a different target removes it at the abort" do
      controller = AbortController.new()
      signal = Request.new(@url, signal: controller.signal).signal
      target = EventTarget.new()

      EventTarget.add_event_listener(target, "x", recorder(:x), signal: signal)
      assert {_target, true} = EventTarget.dispatch_event(target, Event.new("x"))
      assert_received {:x, _event}

      :ok = AbortController.abort(controller)
      assert {_target, true} = EventTarget.dispatch_event(target, Event.new("x"))
      refute_received {:x, _event}

      # The signal is aborted: the listener is not added.
      EventTarget.add_event_listener(target, "x", recorder(:x), signal: signal)
      assert {_target, true} = EventTarget.dispatch_event(target, Event.new("x"))
      refute_received {:x, _event}
    end

    test "a listener with the signal itself as its option :signal keeps the process two times" do
      controller = AbortController.new()
      signal = Request.new(@url, signal: controller.signal).signal

      EventTarget.add_event_listener(signal, "abort", recorder(:abort), signal: signal)
      pid = process_of(signal)
      assert :sys.get_state(pid).keepers == %{}

      # The abort algorithm removes the listener before the event, as the
      # steps "signal abort" specify.
      :ok = AbortController.abort(controller)
      refute_received {:abort, _event}
    end
  end

  describe "a signal whose source aborted" do
    test "starts no process that stays, and an operation has no effect" do
      controller = AbortController.new()
      :ok = AbortController.abort(controller, :why)
      assert_down(controller.signal.pid)
      signal = Request.new(@url, signal: controller.signal).signal

      assert EventTarget.add_event_listener(signal, "abort", recorder(:abort)) == signal
      assert AbortSignal.onabort(signal, recorder(:handler)) == signal

      assert AbortSignal.__add_algorithm__(signal, {Kernel, :send, [self(), :algorithm]}) ==
               :aborted

      assert process_of(signal) == nil
      assert AbortSignal.onabort(signal) == nil
      assert AbortSignal.reason(signal) == :why
    end

    test "while the steps of the abort run, starts a process that stops at once" do
      controller = AbortController.new()
      signal = Request.new(@url, signal: controller.signal).signal
      test = self()

      # The listener runs in this process, while the process of the source
      # is alive and aborted.
      EventTarget.add_event_listener(controller.signal, "abort", fn ->
        EventTarget.add_event_listener(signal, "abort", recorder(:late))
        send(test, {:late_process, process_of(signal)})
      end)

      :ok = AbortController.abort(controller, :why)
      assert_received {:late_process, nil}
      refute_received {:late, _event}
    end
  end

  describe "the process of a lazy signal" do
    test "that stops before the keep of a copy is started again" do
      controller = AbortController.new()
      signal = Request.new(@url, signal: controller.signal).signal
      first = copy()
      x_listener = recorder(:x)
      abort_listener = recorder(:abort)
      run(first, fn -> EventTarget.add_event_listener(signal, "x", x_listener) end)
      pid = process_of(signal)

      # The copy finds the process and waits for its keep. The process stops
      # before it answers.
      :erlang.suspend_process(pid)
      second = copy()

      send(
        second,
        {:run, self(), fn -> EventTarget.add_event_listener(signal, "abort", abort_listener) end}
      )

      wait_until(fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 1} end)
      Process.exit(pid, :kill)
      assert_receive {:ran, ^second, ^signal}

      new_pid = process_of(signal)
      assert is_pid(new_pid) and new_pid != pid
      :ok = AbortController.abort(controller)
      assert_received {:abort, _event}
    end

    test "removes a keeper that stops" do
      controller = AbortController.new()
      signal = Request.new(@url, signal: controller.signal).signal
      test = self()

      keeper =
        spawn(fn ->
          AbortSignal.__with_process__(signal, :ok, fn pid ->
            send(test, {:kept, pid})
            Process.sleep(:infinity)
          end)
        end)

      assert_receive {:kept, pid}
      assert Map.has_key?(:sys.get_state(pid).keepers, keeper)
      Process.exit(keeper, :kill)
      wait_until(fn -> :sys.get_state(pid).keepers == %{} end)
    end
  end

  describe "AbortSignal.any/1" do
    test "depends on the source of a lazy signal" do
      controller = AbortController.new()
      signal = Request.new(@url, signal: controller.signal).signal
      any = AbortSignal.any([signal, Request.new(@url).signal, %AbortSignal{}])

      assert :sys.get_state(any.pid).sources == [controller.signal]
      refute AbortSignal.aborted?(any)
      :ok = AbortController.abort(controller, :why)
      assert AbortSignal.reason(any) == :why
      assert AbortSignal.reason(AbortSignal.any([signal])) == :why
      refute AbortSignal.aborted?(AbortSignal.any([Request.new(@url).signal]))
    end
  end

  describe "fetch/2" do
    test "starts no process for the signal, and rejects with the reason of the source" do
      controller = AbortController.new()
      response = await(Web.fetch("data:,body", signal: controller.signal))
      assert response.status == 200
      assert dependents(controller.signal) == []

      request = Request.new("data:,body", signal: controller.signal)
      :ok = AbortController.abort(controller, :why)
      assert catch_exit(await(Web.fetch(request))) == :why
    end
  end

  describe "the body of a request" do
    test "is not aborted by the signal of the request, as the steps consume body specify" do
      controller = AbortController.new()
      form = Web.FormData.new() |> Web.FormData.append("name", "value")
      text = Request.new(@url, method: "POST", body: "text", signal: controller.signal)
      form = Request.new(@url, method: "POST", body: form, signal: controller.signal)
      :ok = AbortController.abort(controller, :why)

      assert await(Request.text(text)) == "text"
      assert Web.FormData.get(await(Request.form_data(form)), "name") == "value"
    end

    # The ambient signal of the time when the request was made stops
    # `form_data/1`, for example the signal of a `fetch` for its response.
    test "is aborted by the ambient signal of the time when the request was made" do
      controller = AbortController.new()
      :ok = AbortController.abort(controller, :why)
      urlencoded = [{"content-type", "application/x-www-form-urlencoded"}]
      multipart = [{"content-type", "multipart/form-data; boundary=x"}]

      # The bodies are made before: they have no ambient signal.
      bodies = [
        {Web.ReadableStream.__from__("a=1"), urlencoded},
        {Web.ReadableStream.new(%{pull: &Web.ReadableStreamDefaultController.close/1}),
         urlencoded},
        {Web.ReadableStream.from(["--x--\r\n"]), multipart}
      ]

      for {body, headers} <- bodies do
        request =
          Web.AsyncContext.with_signal(controller.signal, fn ->
            Request.new(@url, method: "POST", body: body, headers: headers, duplex: "half")
          end)

        assert catch_exit(await(Request.form_data(request))) == :why
      end
    end
  end

  describe "a copy on a different node" do
    @describetag :cluster

    test "uses the process on the node of the signal, and does nothing when that node stops" do
      {peer, node} = Web.TestCluster.start_peer()

      # Agents on the second node make the controller and the request, and
      # keep them there.
      {:ok, owner} = :erpc.call(node, Agent, :start, [AbortController, :new, []])
      controller = :erpc.call(node, Agent, :get, [owner, Function, :identity, []])
      init = [signal: controller.signal]
      {:ok, keeper} = :erpc.call(node, Agent, :start, [Request, :new, [@url, init]])
      signal = :erpc.call(node, Agent, :get, [keeper, Function, :identity, []]).signal
      assert node(signal.ref) == node

      assert EventTarget.add_event_listener(signal, "abort", recorder(:abort)) == signal
      pid = process_of(signal)
      assert node(pid) == node
      assert :erpc.call(node, AbortSignal, :__listener_pid__, [signal]) == pid

      # The process that aborts runs the listener: it must be on this node,
      # because a function of a test file is not on the second node.
      :ok = AbortController.abort(controller, :why)
      assert_receive {:abort, %Event{target: ^signal}}

      :ok = :peer.stop(peer)
      assert EventTarget.add_event_listener(signal, "abort", recorder(:late)) == signal
      assert process_of(signal) == nil
      assert AbortSignal.onabort(signal) == nil
      assert AbortSignal.aborted?(signal)
    end
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && wait_until(fun, attempts - 1)
    end
  end
end
