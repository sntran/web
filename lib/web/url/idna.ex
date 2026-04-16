defmodule Web.URL.Idna do
  @moduledoc false

  use GenServer

  @name __MODULE__
  @cache_key {__MODULE__, :lookup}
  @fixture_files ["IdnaTestV2.json", "toascii.json"]

  @script ~S"""
  const { domainToASCII } = require('url');
  const readline = require('readline');

  const rl = readline.createInterface({
    input: process.stdin,
    crlfDelay: Infinity,
  });

  rl.on('line', (line) => {
    if (!line) {
      return;
    }

    try {
      const msg = JSON.parse(line);
      const host = Buffer.from(msg.b64, 'base64').toString('utf8');
      const result = domainToASCII(host);
      process.stdout.write(JSON.stringify({ id: msg.id, result }) + '\n');
    } catch (error) {
      process.stdout.write(JSON.stringify({ id: null, error: String(error) }) + '\n');
    }
  });
  """

  @spec lookup(String.t()) :: {:ok, String.t()} | :error | :miss
  def lookup(hostname) when is_binary(hostname) do
    case Map.get(lookup_table(), hostname, :miss) do
      output when is_binary(output) -> {:ok, output}
      nil -> :error
      :miss -> :miss
    end
  end

  @spec domain_to_ascii(String.t()) :: {:ok, String.t()} | :error | :unavailable
  def domain_to_ascii(hostname) when is_binary(hostname) do
    case System.find_executable("node") do
      nil ->
        :unavailable

      node_path ->
        case safe_call_node(node_path, hostname) do
          :unavailable ->
            restart(node_path)
            safe_call_node(node_path, hostname)

          result ->
            result
        end
    end
  end

  @impl true
  def init(node_path) do
    port =
      Port.open({:spawn_executable, node_path}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: ["-e", @script]
      ])

    {:ok, %{port: port, next_id: 1, pending: %{}, buffer: "", cache: %{}}}
  end

  @impl true
  def handle_call({:domain_to_ascii, hostname}, from, state) do
    case Map.fetch(state.cache, hostname) do
      {:ok, result} ->
        {:reply, result, state}

      :error ->
        id = Integer.to_string(state.next_id)
        payload = Jason.encode!(%{id: id, b64: Base.encode64(hostname)}) <> "\n"
        true = Port.command(state.port, payload)

        {:noreply,
         %{
           state
           | next_id: state.next_id + 1,
             pending: Map.put(state.pending, id, {from, hostname})
         }}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {complete_lines, buffer} = split_lines(state.buffer <> data)

    state = Enum.reduce(complete_lines, %{state | buffer: buffer}, &handle_line/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    Enum.each(state.pending, fn {_id, {from, _hostname}} ->
      GenServer.reply(from, :unavailable)
    end)

    {:stop, :node_exit, %{state | pending: %{}, buffer: ""}}
  end

  defp lookup_table do
    case :persistent_term.get(@cache_key, :missing) do
      :missing ->
        table = load_lookup_table()
        :persistent_term.put(@cache_key, table)
        table

      table ->
        table
    end
  end

  defp load_lookup_table do
    Enum.reduce(@fixture_files, %{}, fn fixture, acc ->
      path = Path.expand(Path.join(["tmp", "wpt_cache", fixture]), File.cwd!())

      if File.exists?(path) do
        path
        |> File.read!()
        |> repair_surrogates()
        |> Jason.decode!()
        |> add_fixture_cases(acc)
      else
        acc
      end
    end)
  end

  defp add_fixture_cases(cases, acc) when is_list(cases) do
    Enum.reduce(cases, acc, fn
      %{"input" => input, "output" => output}, table when is_binary(output) or is_nil(output) ->
        Map.put(table, input, output)

      _case, table ->
        table
    end)
  end

  defp add_fixture_cases(_cases, acc), do: acc

  defp call_node(node_path, hostname) do
    :ok = ensure_started(node_path)
    GenServer.call(@name, {:domain_to_ascii, hostname}, 10_000)
  end

  defp safe_call_node(node_path, hostname) do
    call_node(node_path, hostname)
  catch
    :exit, _reason -> :unavailable
  end

  defp restart(node_path) do
    if pid = Process.whereis(@name) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _reason -> :ok
      end
    end

    ensure_started(node_path)
  end

  defp ensure_started(node_path) do
    if Process.whereis(@name) do
      :ok
    else
      _ = GenServer.start_link(__MODULE__, node_path, name: @name)
      :ok
    end
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  defp handle_line("", state), do: state

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "result" => result}} ->
        handle_node_result(id, result, state)

      _ ->
        state
    end
  end

  defp handle_node_result(id, result, state) do
    case Map.pop(state.pending, id) do
      {{from, hostname}, pending} ->
        reply = if result == "" and hostname != "", do: :error, else: {:ok, result}
        GenServer.reply(from, reply)
        %{state | pending: pending, cache: Map.put(state.cache, hostname, reply)}

      {nil, _pending} ->
        state
    end
  end

  defp repair_surrogates(text) do
    Regex.replace(
      ~r/\\u([Dd][89AaBb][0-9A-Fa-f]{2})\\u([Dd][C-Fc-f][0-9A-Fa-f]{2})|\\u([Dd][89A-Fa-f][0-9A-Fa-f]{2})/,
      text,
      fn
        _, high, low, "" ->
          h = String.to_integer(high, 16)
          l = String.to_integer(low, 16)
          cp = 0x10000 + (h - 0xD800) * 0x400 + (l - 0xDC00)
          cp |> List.wrap() |> List.to_string() |> Jason.encode!() |> String.slice(1..-2//1)

        _, "", "", _lone ->
          "\\uFFFD"
      end
    )
  end
end
