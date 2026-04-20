defmodule Web.Internal.StructuredData do
  @moduledoc false

  alias Web.ArrayBuffer
  alias Web.Blob
  alias Web.DOMException
  alias Web.File
  alias Web.Headers
  alias Web.Internal.MessagePort, as: MessagePortRuntime
  alias Web.Internal.Reference
  alias Web.MessagePort
  alias Web.TypeError
  alias Web.Uint8Array
  alias Web.URLSearchParams

  @type node_id :: pos_integer()
  @type serialized :: %{root: node_id(), nodes: %{node_id() => map()}}

  @spec clone(term(), keyword()) :: term()
  def clone(value, opts \\ []) do
    value
    |> serialize(opts)
    |> deserialize()
  end

  @spec serialize(term(), keyword()) :: serialized()
  def serialize(value, opts \\ []) do
    {transfer, message_port_recipient} = normalize_transfer!(opts)
    transfer_keys = validate_transfer_list!(transfer)

    {root, ctx} =
      serialize_node(value, %{
        next_id: 1,
        memo: %{},
        nodes: %{},
        transfer: transfer,
        transfer_keys: transfer_keys,
        message_port_recipient: message_port_recipient
      })

    nodes = detach_transferables(transfer, ctx.nodes, message_port_recipient)

    %{root: root, nodes: nodes}
  end

  @spec deserialize(serialized()) :: term()
  def deserialize(%{root: root, nodes: nodes}) when is_integer(root) and is_map(nodes) do
    {value, _memo} = deserialize_node(root, nodes, %{})
    value
  end

  defp normalize_transfer!(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      normalize_keyword_transfer!(opts)
    else
      raise ArgumentError, "structured_clone options must be a keyword list"
    end
  end

  defp normalize_transfer!(other) do
    raise ArgumentError, "structured_clone options must be a keyword list, got: #{inspect(other)}"
  end

  defp normalize_keyword_transfer!(opts) do
    case Keyword.keys(opts) -- [:transfer, :message_port_recipient] do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown structured_clone options: #{inspect(unknown)}"
    end

    transfer = Keyword.get(opts, :transfer, [])

    message_port_recipient =
      validate_message_port_recipient!(Keyword.get(opts, :message_port_recipient))

    if is_list(transfer) do
      {transfer, message_port_recipient}
    else
      raise ArgumentError, "structured_clone transfer option must be a list"
    end
  end

  defp validate_message_port_recipient!(nil), do: nil

  defp validate_message_port_recipient!(message_port_recipient)
       when is_pid(message_port_recipient), do: message_port_recipient

  defp validate_message_port_recipient!(_other) do
    raise ArgumentError, "structured_clone message_port_recipient must be a pid or nil"
  end

  defp validate_transfer_list!(transfer) do
    Enum.reduce(transfer, MapSet.new(), fn item, seen ->
      validate_transferable!(item)
      key = transfer_key!(item)

      if MapSet.member?(seen, key) do
        data_clone_error!("Transfer list contains duplicate entries")
      else
        MapSet.put(seen, key)
      end
    end)
  end

  defp validate_transferable!(%ArrayBuffer{} = buffer) do
    if ArrayBuffer.detached?(buffer) do
      raise TypeError.exception("Cannot structured_clone a detached ArrayBuffer")
    end

    :ok
  end

  defp validate_transferable!(%MessagePort{} = port) do
    MessagePortRuntime.ensure_transferable(port)
  end

  defp validate_transferable!(other) do
    data_clone_error!("Transfer list contains a non-transferable value: #{inspect(other)}")
  end

  defp serialize_node(value, ctx) do
    case memo_key(value) do
      {:ok, key} when is_map_key(ctx.memo, key) ->
        {Map.fetch!(ctx.memo, key), ctx}

      _ ->
        serialize_fresh(value, ctx)
    end
  end

  defp serialize_fresh(value, ctx) do
    case reserve_node(value, ctx) do
      {:ok, id, next_ctx} -> serialize_reserved(value, id, next_ctx)
      # coveralls-ignore-next-line
      :error -> serialize_reserved(value, nil, ctx)
    end
  end

  defp serialize_reserved(value, id, ctx)

  defp serialize_reserved(value, id, ctx)
       when value in [nil, true, false] or is_integer(value) or is_float(value) or
              is_binary(value) do
    id = ensure_node_id!(id)
    {id, put_node(ctx, id, %{type: :primitive, value: value})}
  end

  defp serialize_reserved(value, _id, _ctx) when is_atom(value) do
    data_clone_error!("Atoms are not structured-clone serializable: #{inspect(value)}")
  end

  defp serialize_reserved(value, _id, _ctx) when is_pid(value) do
    data_clone_error!("PIDs are not structured-clone serializable")
  end

  defp serialize_reserved(value, _id, _ctx) when is_port(value) do
    data_clone_error!("Ports are not structured-clone serializable")
  end

  defp serialize_reserved(value, _id, _ctx) when is_function(value) do
    data_clone_error!("Functions are not structured-clone serializable")
  end

  defp serialize_reserved(value, _id, _ctx) when is_reference(value) do
    data_clone_error!("References are not structured-clone serializable")
  end

  defp serialize_reserved(%DateTime{} = value, id, ctx) do
    id = ensure_node_id!(id)
    {id, put_node(ctx, id, %{type: :date_time, value: Map.from_struct(value)})}
  end

  defp serialize_reserved(%Regex{} = value, id, ctx) do
    id = ensure_node_id!(id)
    node = %{type: :regex, source: Regex.source(value), opts: Regex.opts(value)}
    {id, put_node(ctx, id, node)}
  end

  defp serialize_reserved(%ArrayBuffer{} = value, id, ctx) do
    id = ensure_node_id!(id)

    if ArrayBuffer.detached?(value) do
      raise TypeError.exception("Cannot structured_clone a detached ArrayBuffer")
    end

    node = %{
      type: :array_buffer,
      data: ArrayBuffer.data(value),
      transferred: MapSet.member?(ctx.transfer_keys, transfer_key!(value))
    }

    {id, put_node(ctx, id, node)}
  end

  defp serialize_reserved(%MessagePort{} = value, id, ctx) do
    id = ensure_node_id!(id)

    if MapSet.member?(ctx.transfer_keys, transfer_key!(value)) do
      {id, put_node(ctx, id, %{type: :message_port, address: value.address, token: value.token})}
    else
      data_clone_error!("MessagePort values must be transferred")
    end
  end

  defp serialize_reserved(%Uint8Array{} = value, id, ctx) do
    id = ensure_node_id!(id)
    {buffer_id, final_ctx} = serialize_node(value.buffer, ctx)

    node = %{
      type: :uint8_array,
      buffer: buffer_id,
      byte_offset: value.byte_offset,
      byte_length: value.byte_length
    }

    {id, put_node(final_ctx, id, node)}
  end

  defp serialize_reserved(%Blob{} = value, id, ctx) do
    id = ensure_node_id!(id)
    {part_ids, final_ctx} = serialize_many(value.parts, ctx)

    node = %{type: :blob, parts: part_ids, blob_type: value.type}
    {id, put_node(final_ctx, id, node)}
  end

  defp serialize_reserved(%File{stream: nil} = value, id, ctx) do
    id = ensure_node_id!(id)
    {part_ids, final_ctx} = serialize_many(value.parts, ctx)

    node = %{
      type: :file,
      parts: part_ids,
      file_type: value.type,
      name: value.name,
      filename: value.filename,
      size: value.size
    }

    {id, put_node(final_ctx, id, node)}
  end

  defp serialize_reserved(%File{}, _id, _ctx) do
    data_clone_error!("Files backed by a live stream are not structured-clone serializable")
  end

  defp serialize_reserved(%Headers{} = value, id, ctx) do
    id = ensure_node_id!(id)
    node = %{type: :headers, entries: Headers.to_list(value)}
    {id, put_node(ctx, id, node)}
  end

  defp serialize_reserved(%URLSearchParams{} = value, id, ctx) do
    id = ensure_node_id!(id)
    node = %{type: :url_search_params, pairs: URLSearchParams.to_list(value)}
    {id, put_node(ctx, id, node)}
  end

  defp serialize_reserved(%MapSet{} = value, id, ctx) do
    id = ensure_node_id!(id)
    {item_ids, final_ctx} = serialize_many(MapSet.to_list(value), ctx)
    {id, put_node(final_ctx, id, %{type: :map_set, items: item_ids})}
  end

  defp serialize_reserved(value, id, ctx) when is_list(value) do
    id = ensure_node_id!(id)
    {item_ids, final_ctx} = serialize_many(value, ctx)
    {id, put_node(final_ctx, id, %{type: :list, items: item_ids})}
  end

  defp serialize_reserved(value, id, ctx) when is_map(value) do
    id = ensure_node_id!(id)
    {entries, final_ctx} = serialize_map_entries(Map.to_list(value), ctx)
    {id, put_node(final_ctx, id, %{type: :map, entries: entries})}
  end

  defp serialize_reserved(value, _id, _ctx) when is_tuple(value) do
    data_clone_error!("Tuples are not structured-clone serializable: #{inspect(value)}")
  end

  defp serialize_reserved(value, _id, _ctx) do
    data_clone_error!("Value is not structured-clone serializable: #{inspect(value)}")
  end

  defp serialize_many(values, ctx) do
    Enum.map_reduce(values, ctx, fn value, acc ->
      serialize_node(value, acc)
    end)
  end

  defp serialize_map_entries(entries, ctx) do
    Enum.map_reduce(entries, ctx, fn {key, value}, acc ->
      {key_id, next_acc} = serialize_node(key, acc)
      {value_id, final_acc} = serialize_node(value, next_acc)
      {{key_id, value_id}, final_acc}
    end)
  end

  defp deserialize_node(id, nodes, memo) do
    case Map.get(memo, id) do
      {:done, value} ->
        {value, memo}

      :pending ->
        {%Reference{id: id}, memo}

      nil ->
        memo = Map.put(memo, id, :pending)
        {value, next_memo} = build_node(Map.fetch!(nodes, id), nodes, memo)
        {value, Map.put(next_memo, id, {:done, value})}
    end
  end

  defp build_node(%{type: :primitive, value: value}, _nodes, memo), do: {value, memo}

  defp build_node(%{type: :date_time, value: value}, _nodes, memo) do
    {struct(DateTime, value), memo}
  end

  defp build_node(%{type: :regex, source: source, opts: opts}, _nodes, memo) do
    {Regex.compile!(source, opts), memo}
  end

  defp build_node(%{type: :array_buffer, data: data}, _nodes, memo) do
    {ArrayBuffer.new(data), memo}
  end

  defp build_node(%{type: :message_port, address: address, token: token}, _nodes, memo) do
    {MessagePortRuntime.deserialize(%{address: address, token: token}), memo}
  end

  defp build_node(
         %{type: :uint8_array, buffer: buffer_id, byte_offset: offset, byte_length: length},
         nodes,
         memo
       ) do
    {buffer, next_memo} = deserialize_node(buffer_id, nodes, memo)
    {Uint8Array.new(buffer, offset, length), next_memo}
  end

  defp build_node(%{type: :blob, parts: part_ids, blob_type: blob_type}, nodes, memo) do
    {parts, next_memo} = deserialize_many(part_ids, nodes, memo)
    {Blob.new(parts, type: blob_type), next_memo}
  end

  defp build_node(
         %{
           type: :file,
           parts: part_ids,
           file_type: file_type,
           name: name,
           filename: filename,
           size: size
         },
         nodes,
         memo
       ) do
    {parts, next_memo} = deserialize_many(part_ids, nodes, memo)

    file =
      File.new(parts, name: name, filename: filename, type: file_type, size: size, stream: nil)

    {file, next_memo}
  end

  defp build_node(%{type: :headers, entries: entries}, _nodes, memo) do
    {Headers.new(entries), memo}
  end

  defp build_node(%{type: :url_search_params, pairs: pairs}, _nodes, memo) do
    {URLSearchParams.new(pairs), memo}
  end

  defp build_node(%{type: :map_set, items: item_ids}, nodes, memo) do
    {items, next_memo} = deserialize_many(item_ids, nodes, memo)
    {MapSet.new(items), next_memo}
  end

  defp build_node(%{type: :list, items: item_ids}, nodes, memo) do
    deserialize_many(item_ids, nodes, memo)
  end

  defp build_node(%{type: :map, entries: entries}, nodes, memo) do
    Enum.reduce(entries, {%{}, memo}, fn {key_id, value_id}, {acc, current_memo} ->
      {key, next_memo} = deserialize_node(key_id, nodes, current_memo)
      {value, final_memo} = deserialize_node(value_id, nodes, next_memo)
      {Map.put(acc, key, value), final_memo}
    end)
  end

  defp deserialize_many(ids, nodes, memo) do
    Enum.map_reduce(ids, memo, fn id, acc ->
      deserialize_node(id, nodes, acc)
    end)
  end

  defp reserve_node(value, ctx) do
    case memo_key(value) do
      {:ok, key} ->
        id = ctx.next_id

        next_ctx = %{
          ctx
          | next_id: id + 1,
            memo: Map.put(ctx.memo, key, id),
            nodes: Map.put(ctx.nodes, id, :pending)
        }

        {:ok, id, next_ctx}

      # coveralls-ignore-next-line
      :error ->
        :error
    end
  end

  defp put_node(ctx, id, node) do
    %{ctx | nodes: Map.put(ctx.nodes, id, node)}
  end

  defp detach_transferables(transfer, nodes, message_port_recipient) do
    Enum.reduce(transfer, nodes, fn
      %ArrayBuffer{} = buffer, current_nodes ->
        ArrayBuffer.detach(buffer)
        current_nodes

      %MessagePort{} = port, current_nodes ->
        detached_fields = detach_message_port(port, message_port_recipient)
        rewrite_transferred_message_port(current_nodes, port, detached_fields)
    end)
  end

  defp detach_message_port(%MessagePort{} = port, message_port_recipient)
       when is_pid(message_port_recipient) do
    MessagePortRuntime.detach_transferable(port, message_port_recipient)
  end

  defp detach_message_port(%MessagePort{}, nil) do
    data_clone_error!("MessagePort transfers require a recipient process")
  end

  defp rewrite_transferred_message_port(
         nodes,
         %MessagePort{address: address, token: token},
         detached_fields
       ) do
    Map.new(nodes, fn {id, node} ->
      {id, rewrite_transferred_message_port_node(node, {address, token}, detached_fields)}
    end)
  end

  defp rewrite_transferred_message_port_node(
         %{type: :message_port, address: address, token: token} = node,
         {address, token},
         %{address: next_address, token: next_token}
       ) do
    %{node | address: next_address, token: next_token}
  end

  defp rewrite_transferred_message_port_node(node, _current_handle, _detached_fields), do: node

  defp transfer_key!(%ArrayBuffer{} = buffer) do
    case ArrayBuffer.identity(buffer) do
      id when is_reference(id) -> {:transferable, ArrayBuffer, id}
      _other -> memo_key!(buffer)
    end
  end

  defp transfer_key!(%MessagePort{address: address, token: token})
       when is_reference(address) and is_reference(token) do
    {:transferable, MessagePort, address, token}
  end

  defp memo_key(%ArrayBuffer{} = value) do
    reference_memo_key(ArrayBuffer, ArrayBuffer.identity(value), value)
  end

  defp memo_key(%MessagePort{address: address, token: token})
       when is_reference(address) and is_reference(token) do
    {:ok, {:reference, MessagePort, address, token}}
  end

  defp memo_key(%Uint8Array{} = value) do
    reference_memo_key(Uint8Array, Uint8Array.identity(value), value)
  end

  defp memo_key(%Blob{} = value) do
    reference_memo_key(Blob, Blob.identity(value), value)
  end

  defp memo_key(%File{} = value) do
    reference_memo_key(File, File.identity(value), value)
  end

  defp memo_key(value) do
    {:ok, :erlang.term_to_binary(value)}
  catch
    # coveralls-ignore-next-line
    :error, :badarg -> :error
  end

  defp memo_key!(value) do
    case memo_key(value) do
      {:ok, key} -> key
      # coveralls-ignore-next-line
      :error -> data_clone_error!("Value is not structured-clone serializable: #{inspect(value)}")
    end
  end

  defp reference_memo_key(module, id, _value) when is_reference(id) do
    {:ok, {:reference, module, id}}
  end

  defp reference_memo_key(_module, _id, value) do
    {:ok, :erlang.term_to_binary(value)}
  catch
    # coveralls-ignore-next-line
    :error, :badarg -> :error
  end

  defp ensure_node_id!(id) when is_integer(id), do: id

  defp ensure_node_id!(_id) do
    # coveralls-ignore-next-line
    raise ArgumentError, "structured clone memoization failed to reserve a node id"
  end

  defp data_clone_error!(message) do
    raise DOMException, name: "DataCloneError", message: message
  end
end
