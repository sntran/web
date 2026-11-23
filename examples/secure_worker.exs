defmodule SecureWorkerExample do
  @moduledoc """
  Demonstrates capability handover with `MessageChannel` and `MessagePort`.

  Usage:
    mix run examples/secure_worker.exs
  """

  use Web

  def run do
    owner = self()
    %{port1: controller_bootstrap, port2: worker_bootstrap} = MessageChannel.new()
    %{port1: client_port, port2: service_port} = MessageChannel.new()

    worker_pid =
      spawn(fn ->
        secrets = %{
          "db_password" => "db://prod/primary",
          "signing_key" => "signing-key-v1"
        }

        worker_loop(%{
          owner: owner,
          bootstrap: worker_bootstrap,
          request_port: nil,
          secrets: secrets
        })
      end)

    MessagePort.onmessage(client_port, fn event ->
      send(owner, {:client_reply, event.data})
    end)

    :ok =
      MessagePort.post_message(
        controller_bootstrap,
        %{"port" => service_port},
        [service_port]
      )

    await_handover()
    direct_pid_result = direct_pid_attack_result(worker_pid)

    # A handle with a token that is not correct is a detached handle. As in
    # a browser, a message on such a handle gives no error and has no
    # effect: the worker gets nothing, thus no answer comes.
    forged_port = %{client_port | token: make_ref()}
    :ok = MessagePort.post_message(forged_port, %{"op" => "read", "key" => "db_password"})

    forged_result =
      receive do
        {:client_reply, _reply} -> :unexpected_reply
      after
        200 -> :no_effect
      end

    :ok = MessagePort.post_message(client_port, %{"op" => "read", "key" => "db_password"})
    secret_reply = await_client_reply()

    print_summary(worker_pid, direct_pid_result, forged_result, secret_reply)

    :ok = MessagePort.close(controller_bootstrap)
    :ok = MessagePort.close(client_port)
  end

  defp worker_loop(%{bootstrap: bootstrap, request_port: nil, owner: owner} = state) do
    worker_pid = self()

    bootstrap =
      MessagePort.onmessage(bootstrap, fn event ->
        send(worker_pid, {:bootstrap_handover, event.data["port"]})
      end)

    receive do
      {:bootstrap_handover, %MessagePort{} = request_port} ->
        request_port =
          MessagePort.onmessage(request_port, fn event ->
            send(worker_pid, {:service_request, event.data})
          end)

        send(owner, :handover_complete)
        worker_loop(%{state | bootstrap: bootstrap, request_port: request_port})
    end
  end

  defp worker_loop(%{request_port: request_port, secrets: secrets} = state) do
    receive do
      {:service_request, %{"op" => "read", "key" => key}} ->
        reply =
          case Map.fetch(secrets, key) do
            {:ok, value} -> %{"status" => "ok", "value" => value}
            :error -> %{"status" => "error", "message" => "unknown key"}
          end

        :ok = MessagePort.post_message(request_port, reply)
        worker_loop(state)

      {:dump_secret, _from} ->
        worker_loop(state)

      _other ->
        worker_loop(state)
    end
  end

  defp await_handover(timeout \\ 1_000) do
    receive do
      :handover_complete -> :ok
    after
      timeout -> raise "timed out waiting for worker handover"
    end
  end

  defp await_client_reply(timeout \\ 1_000) do
    receive do
      {:client_reply, %{"status" => "ok", "value" => value}} -> value
      {:client_reply, other} -> raise "unexpected client reply: #{inspect(other)}"
    after
      timeout -> raise "timed out waiting for client reply"
    end
  end

  defp direct_pid_attack_result(worker_pid, timeout \\ 200) do
    send(worker_pid, {:dump_secret, self()})

    receive do
      {:pid_attack_reply, ^worker_pid} -> :compromised
    after
      timeout -> :ignored
    end
  end

  defp print_summary(worker_pid, direct_pid_result, forged_result, secret_reply) do
    IO.puts("Worker PID is known: #{inspect(worker_pid)}")
    IO.puts("Direct PID attack result: #{inspect(direct_pid_result)}")
    IO.puts("Forged port result: #{inspect(forged_result)}")
    IO.puts("Secret fetched through transferred capability: #{secret_reply}")
  end
end

SecureWorkerExample.run()
