defmodule Instance.StellarSystem.ProductionQueue do
  use TypedStruct

  alias Instance.StellarSystem

  def jason(), do: []

  typedstruct enforce: true do
    field(:queue, [%StellarSystem.ProductionItem{}] | [])
  end

  def new() do
    %StellarSystem.ProductionQueue{
      queue: Queue.new()
    }
  end

  def queue_item(%{queue: queue}, type, production_data) do
    # max + 1, not last + 1: once the queue can be reordered the last item
    # is no longer the newest, and a duplicate id would make cancel
    # (which filters by id) remove two items for one refund.
    id =
      queue
      |> Queue.to_list()
      |> Enum.reduce(0, fn item, acc -> max(item.id, acc) end)
      |> Kernel.+(1)

    %{queue: Queue.insert(queue, StellarSystem.ProductionItem.new(type, production_data, id))}
  end

  @doc """
  Reorders the queue to follow `ids`, which must be exactly the ids
  currently queued (a permutation). Anything else — a stale client view,
  a missing, extra, or duplicated id — is `{:error, :queue_changed}`.

  Only the head accumulates production, and progress is NOT carried
  across a reorder: every item that is not the head afterwards is reset
  to its full cost, so displacing a nearly-finished head throws its
  progress away instead of handing it to whatever replaced it. The head
  keeps its progress only when it stays the head.
  """
  def reorder(%{queue: queue}, ids) when is_list(ids) do
    items = Queue.to_list(queue)
    current_ids = Enum.map(items, & &1.id)

    if length(ids) == length(current_ids) and Enum.sort(ids) == Enum.sort(current_ids) do
      by_id = Map.new(items, &{&1.id, &1})
      old_head_id = List.first(current_ids)

      reordered =
        ids
        |> Enum.map(&Map.fetch!(by_id, &1))
        |> Enum.with_index()
        |> Enum.map(fn
          {%{id: ^old_head_id} = item, 0} -> item
          {item, _} -> %{item | remaining_prod: item.total_prod}
        end)

      {:ok, %{queue: Queue.new(reordered)}}
    else
      {:error, :queue_changed}
    end
  end

  def reorder(_queue, _ids), do: {:error, :queue_changed}

  def unqueue_item(%{queue: queue}, production_id) do
    if Queue.empty?(queue) do
      {:error, :queue_empty}
    else
      item =
        queue
        |> Queue.filter(fn i -> i.id == production_id end)
        |> Queue.to_list()
        |> List.first()

      if item do
        queue = Queue.filter(queue, fn i -> i.id != production_id end)
        {:ok, item, %{queue: queue}}
      else
        {:error, :item_not_found}
      end
    end
  end

  def unqueue_last_item(%{queue: queue}) do
    if Queue.empty?(queue) do
      {:queue_empty, %{queue: queue}}
    else
      {item, queue} = Queue.pop_rear(queue)

      {:ok, item, %{queue: queue}}
    end
  end

  def add_production(%{queue: queue}, production) do
    if Queue.empty?(queue) do
      %{queue: queue}
    else
      {item, queue} = Queue.pop(queue)

      case StellarSystem.ProductionItem.add_production(item, production) do
        {:unfinished, updated_item} ->
          %{queue: Queue.insert_front(queue, updated_item)}

        {:finished, rest} ->
          {%{queue: queue}, rest, item}
      end
    end
  end

  @doc """
  Rejects production items that have target_id AND type
  """
  def reject_items(%{queue: queue}, target_id, type) do
    %{queue: Queue.filter(queue, fn item -> item.target_id != target_id or item.type != type end)}
  end

  def get_next_action_remaining_time(stellar_system) do
    case Queue.peek(stellar_system.queue.queue) do
      nil ->
        :never

      item ->
        if stellar_system.production.value == 0,
          do: 0,
          else: item.remaining_prod / stellar_system.production.value
    end
  end

  def get_total_remaining_time(stellar_system) do
    items = Queue.to_list(stellar_system.queue.queue)

    case items do
      [] ->
        :never

      _ ->
        if stellar_system.production.value == 0 do
          0
        else
          total_prod = Enum.reduce(items, 0, fn item, acc -> acc + item.remaining_prod end)
          total_prod / stellar_system.production.value
        end
    end
  end
end
