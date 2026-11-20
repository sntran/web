defmodule Web.Internal.StructuredData do
  @moduledoc false

  # The structured clone algorithm of the HTML Standard, for Elixir terms.
  #
  # `serialize/2` makes a record in the process that sends a value, and
  # `deserialize/1` makes the value again in the process that gets it. A
  # message port and a broadcast channel send the record between the two.
  #
  # An Elixir term cannot change, thus a copy of plain data is the same
  # term. Only a value that has an identity gets a new one: a
  # `Web.ArrayBuffer`, a `Web.Uint8Array`, a `Web.Blob`, and a `Web.File`.
  # The record replaces each of these values with a `Node`. The function
  # `deserialize/1` makes one new value for each node. Two references to
  # one value in the input are two references to one new value in the
  # result.
  #
  # The algorithm reads the input one time to find the values that cannot
  # be cloned. It builds a new term only when the input has a value with an
  # identity.

  alias Web.ArrayBuffer
  alias Web.Blob
  alias Web.DOMException
  alias Web.File
  alias Web.Internal.MessagePort, as: PortEngine
  alias Web.MessagePort
  alias Web.TypeError
  alias Web.Uint8Array

  defmodule Record do
    @moduledoc false

    # `plain` is true when `value` has no `Node`. Then `value` is the result.
    # `ports` has the new handles of the message ports of the transfer list,
    # in the sequence of that list.
    @enforce_keys [:value, :plain]
    defstruct [:value, :plain, ports: []]

    @type t :: %__MODULE__{value: term(), plain: boolean(), ports: [map()]}
  end

  defmodule Node do
    @moduledoc false

    # Replaces, in a record, a value that has an identity. Two nodes with
    # the same key become one value.
    @enforce_keys [:type, :key]
    defstruct [:type, :key, :data]
  end

  @type option :: {:transfer, list()} | {:port_holder, pid()}

  @doc """
  Returns a structured clone of `value`.
  """
  @spec clone(term(), [option()]) :: term()
  def clone(value, opts \\ []) do
    value
    |> serialize(opts)
    |> deserialize()
  end

  @doc """
  Makes the record of `value`, and moves each value of the transfer list.

  The option `:port_holder` is the process that keeps a transferred message
  port alive. The default is the process that calls this function.

  The function changes nothing when it raises.
  """
  @spec serialize(term(), [option()]) :: Record.t()
  def serialize(value, opts \\ []) do
    {transfer, holder} = options!(opts)
    transfer_keys = transfer_keys!(transfer)

    special? = scan(value, false, %{transfer: transfer_keys, inside: nil})
    :ok = Enum.each(transfer, &attached!/1)

    {tree, plain?} =
      if special? do
        {tree, _ctx} = build(value, %{memo: %{}, next: 0, transfer: transfer_keys})
        {tree, false}
      else
        {value, true}
      end

    %Record{value: tree, plain: plain?, ports: move(transfer, holder)}
  end

  @doc """
  Makes the value of a record.
  """
  @spec deserialize(Record.t()) :: term()
  def deserialize(%Record{} = record) do
    {value, _ports} = deserialize_with_ports(record)
    value
  end

  @doc """
  Makes the value of a record, and the list of the transferred message
  ports.
  """
  @spec deserialize_with_ports(Record.t()) :: {term(), [MessagePort.t()]}
  def deserialize_with_ports(%Record{value: value, plain: true, ports: ports}) do
    {value, Enum.map(ports, &PortEngine.deserialize/1)}
  end

  def deserialize_with_ports(%Record{value: tree, plain: false, ports: ports}) do
    ports = Enum.map(ports, &PortEngine.deserialize/1)

    memo =
      ports
      |> Enum.with_index()
      |> Map.new(fn {port, index} -> {{:port, index}, port} end)

    {value, _memo} = revive(tree, memo)
    {value, ports}
  end

  # ---------------------------------------------------------------------------
  # Options and the transfer list
  # ---------------------------------------------------------------------------

  defp options!(opts) do
    if not Keyword.keyword?(opts) do
      raise TypeError, "The options must be a keyword list, got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- [:transfer, :port_holder] do
      [] -> :ok
      unknown -> raise TypeError, "Unknown options: #{inspect(unknown)}"
    end

    transfer = Keyword.get(opts, :transfer, [])
    holder = Keyword.get(opts, :port_holder, self())

    if not is_list(transfer) do
      raise TypeError, "The option :transfer must be a list, got: #{inspect(transfer)}"
    end

    if not is_pid(holder) do
      raise TypeError, "The option :port_holder must be a pid, got: #{inspect(holder)}"
    end

    {transfer, holder}
  end

  # The map from the identity of each value of the transfer list to its
  # position in the list.
  defp transfer_keys!(transfer) do
    transfer
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {item, index}, keys ->
      key = transfer_key!(item)

      if is_map_key(keys, key) do
        data_clone_error!("The transfer list has the same value two times.")
      end

      Map.put(keys, key, index)
    end)
  end

  defp transfer_key!(%ArrayBuffer{} = buffer), do: buffer_key(buffer)
  defp transfer_key!(%MessagePort{} = port), do: port_key(port)

  defp transfer_key!(other) do
    data_clone_error!("A value of the transfer list cannot be transferred: #{inspect(other)}")
  end

  defp buffer_key(%ArrayBuffer{} = buffer) do
    case ArrayBuffer.identity(buffer) do
      nil -> {ArrayBuffer, buffer}
      id -> {ArrayBuffer, id}
    end
  end

  defp port_key(%MessagePort{address: address, token: token}), do: {MessagePort, address, token}

  defp attached!(%ArrayBuffer{} = buffer) do
    if ArrayBuffer.detached?(buffer) do
      data_clone_error!("A detached ArrayBuffer cannot be transferred.")
    end
  end

  defp attached!(%MessagePort{} = port), do: PortEngine.ensure_transferable(port)

  # Detaches the buffers, and gives the ports to their new holder.
  defp move(transfer, holder) do
    Enum.flat_map(transfer, fn
      %ArrayBuffer{} = buffer ->
        ArrayBuffer.detach(buffer)
        []

      %MessagePort{} = port ->
        [PortEngine.detach_transferable(port, holder)]
    end)
  end

  # ---------------------------------------------------------------------------
  # The first read: find the values that cannot be cloned
  # ---------------------------------------------------------------------------

  # Returns true when the value has a part that needs a node.
  defp scan(value, special?, _env)
       when is_atom(value) or is_number(value) or is_bitstring(value),
       do: special?

  defp scan([head | tail], special?, env), do: scan(tail, scan(head, special?, env), env)
  defp scan([], special?, _env), do: special?

  defp scan(value, special?, env) when is_tuple(value) do
    scan(Tuple.to_list(value), special?, env)
  end

  defp scan(%ArrayBuffer{} = buffer, _special?, _env) do
    if ArrayBuffer.detached?(buffer) do
      data_clone_error!("A detached ArrayBuffer cannot be cloned.")
    end

    true
  end

  defp scan(%Uint8Array{buffer: buffer}, special?, env), do: scan(buffer, special?, env)

  defp scan(%Blob{parts: parts}, special?, env) do
    _special? = scan(parts, special?, %{env | inside: Blob})
    true
  end

  defp scan(%File{stream: nil, parts: parts}, special?, env) do
    _special? = scan(parts, special?, %{env | inside: File})
    true
  end

  defp scan(%File{}, _special?, _env) do
    data_clone_error!("A file that has a stream cannot be cloned.")
  end

  defp scan(%MessagePort{} = port, _special?, env) do
    if not is_map_key(env.transfer, port_key(port)) do
      data_clone_error!("A MessagePort cannot be cloned. Put it in the transfer list.")
    end

    true
  end

  defp scan(%Regex{}, _special?, _env), do: true

  defp scan(%module{}, _special?, _env) when module in [Record, Node] do
    data_clone_error!("An internal record of the structured clone cannot be cloned.")
  end

  # These structs are not data, also when they have no pid at this time:
  # a promise that is settled, a signal that is aborted, a response with no
  # body, a stream that has no process yet. The Standards do not make them
  # serializable. A stream is transferable in the HTML Standard, not
  # serializable.
  @live [
    Web.Request,
    Web.Response,
    Web.Promise,
    Web.AbortSignal,
    Web.AbortController,
    Web.ReadableStream
  ]

  defp scan(%module{}, _special?, _env) when module in @live do
    data_clone_error!("A #{inspect(module)} cannot be cloned.")
  end

  defp scan(%module{} = struct, special?, env) do
    struct
    |> Map.from_struct()
    |> Map.values()
    |> scan(special?, %{env | inside: module})
  end

  defp scan(%{} = map, special?, env) do
    :maps.fold(fn key, value, acc -> scan(value, scan(key, acc, env), env) end, special?, map)
  end

  defp scan(value, _special?, env) do
    kind =
      cond do
        is_pid(value) -> "A pid"
        is_function(value) -> "A function"
        is_reference(value) -> "A reference"
        is_port(value) -> "A port"
      end

    place =
      case env.inside do
        nil -> ""
        module -> " It is in a #{inspect(module)} struct."
      end

    data_clone_error!("#{kind} cannot be cloned.#{place}")
  end

  # ---------------------------------------------------------------------------
  # The second read: put a node in the place of each value with an identity
  # ---------------------------------------------------------------------------

  defp build(value, ctx)
       when is_atom(value) or is_number(value) or is_bitstring(value),
       do: {value, ctx}

  defp build([head | tail], ctx) do
    {head, ctx} = build(head, ctx)
    {tail, ctx} = build(tail, ctx)
    {[head | tail], ctx}
  end

  defp build([], ctx), do: {[], ctx}

  defp build(value, ctx) when is_tuple(value) do
    {items, ctx} = build(Tuple.to_list(value), ctx)
    {List.to_tuple(items), ctx}
  end

  defp build(%ArrayBuffer{} = buffer, ctx) do
    node(ArrayBuffer, ArrayBuffer.identity(buffer), ctx, fn key, ctx ->
      {%Node{type: :array_buffer, key: key, data: buffer.data}, ctx}
    end)
  end

  defp build(%Uint8Array{} = view, ctx) do
    node(Uint8Array, Uint8Array.identity(view), ctx, fn key, ctx ->
      {buffer, ctx} = build(view.buffer, ctx)
      data = {buffer, view.byte_offset, view.byte_length}
      {%Node{type: :uint8_array, key: key, data: data}, ctx}
    end)
  end

  defp build(%Blob{} = blob, ctx) do
    node(Blob, Blob.identity(blob), ctx, fn key, ctx ->
      {parts, ctx} = build(blob.parts, ctx)
      {%Node{type: :blob, key: key, data: {parts, blob.type}}, ctx}
    end)
  end

  defp build(%File{} = file, ctx) do
    node(File, File.identity(file), ctx, fn key, ctx ->
      {parts, ctx} = build(file.parts, ctx)

      data = [
        name: file.name,
        filename: file.filename,
        type: file.type,
        size: file.size
      ]

      {%Node{type: :file, key: key, data: {parts, data}}, ctx}
    end)
  end

  defp build(%MessagePort{} = port, ctx) do
    index = Map.fetch!(ctx.transfer, port_key(port))
    {%Node{type: :message_port, key: {:port, index}}, ctx}
  end

  # A compiled pattern is not valid on a different node. The record has the
  # source, and the result has a pattern that is compiled again.
  defp build(%Regex{} = regex, ctx) do
    {%Node{type: :regex, key: nil, data: {Regex.source(regex), Regex.opts(regex)}}, ctx}
  end

  defp build(%{} = map, ctx) do
    {pairs, ctx} =
      map
      |> Map.to_list()
      |> Enum.map_reduce(ctx, fn {key, value}, ctx ->
        {key, ctx} = build(key, ctx)
        {value, ctx} = build(value, ctx)
        {{key, value}, ctx}
      end)

    {:maps.from_list(pairs), ctx}
  end

  # Makes one node for one identity. A value with no identity gets a new
  # node each time.
  defp node(_module, nil, ctx, make) do
    make.({:node, ctx.next}, %{ctx | next: ctx.next + 1})
  end

  defp node(module, identity, ctx, make) do
    case ctx.memo do
      %{{^module, ^identity} => node} ->
        {node, ctx}

      _ ->
        {node, ctx} = make.({:node, ctx.next}, %{ctx | next: ctx.next + 1})
        {node, put_in(ctx.memo[{module, identity}], node)}
    end
  end

  # ---------------------------------------------------------------------------
  # The result: make a new value for each node
  # ---------------------------------------------------------------------------

  defp revive(value, memo)
       when is_atom(value) or is_number(value) or is_bitstring(value),
       do: {value, memo}

  defp revive([head | tail], memo) do
    {head, memo} = revive(head, memo)
    {tail, memo} = revive(tail, memo)
    {[head | tail], memo}
  end

  defp revive([], memo), do: {[], memo}

  defp revive(value, memo) when is_tuple(value) do
    {items, memo} = revive(Tuple.to_list(value), memo)
    {List.to_tuple(items), memo}
  end

  defp revive(%Node{type: :regex, data: {source, opts}}, memo) do
    {Regex.compile!(source, opts), memo}
  end

  defp revive(%Node{key: key} = node, memo) do
    case memo do
      %{^key => value} ->
        {value, memo}

      _ ->
        {value, memo} = make(node, memo)
        {value, Map.put(memo, key, value)}
    end
  end

  defp revive(%{} = map, memo) do
    {pairs, memo} =
      map
      |> Map.to_list()
      |> Enum.map_reduce(memo, fn {key, value}, memo ->
        {key, memo} = revive(key, memo)
        {value, memo} = revive(value, memo)
        {{key, value}, memo}
      end)

    {:maps.from_list(pairs), memo}
  end

  defp make(%Node{type: :array_buffer, data: data}, memo), do: {ArrayBuffer.new(data), memo}

  defp make(%Node{type: :uint8_array, data: {buffer, offset, length}}, memo) do
    {buffer, memo} = revive(buffer, memo)
    {Uint8Array.new(buffer, offset, length), memo}
  end

  defp make(%Node{type: :blob, data: {parts, type}}, memo) do
    {parts, memo} = revive(parts, memo)
    {Blob.new(parts, type: type), memo}
  end

  defp make(%Node{type: :file, data: {parts, data}}, memo) do
    {parts, memo} = revive(parts, memo)
    {File.new(parts, data), memo}
  end

  @spec data_clone_error!(String.t()) :: no_return()
  defp data_clone_error!(message) do
    raise DOMException, name: "DataCloneError", message: message
  end
end
