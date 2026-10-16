defmodule WandererAppWeb.ScoutLayout do
  @moduledoc """
  CHEWY PATCH: where every `/scout` panel sits, and whether it is open.

  The scout pages are stacks of boards — twelve on the structures tab
  alone — and which of them matters is per reader and per evening: a
  director watching an unanchoring run wants that board at the top, a
  hunter wants Now and nothing else. The page shipped with ONE order,
  baked into the template, so the only way to change it was to scroll.

  This module is the state behind the collapse chevron, the ▲/▼ buttons
  and the drag handle on `WandererAppWeb.ScoutComponents.panel/1`. It is
  pure: a `%ScoutLayout{}` goes in, one goes out, and the caller decides
  when to persist it.

  Three decisions worth keeping:

    * **Order is per STACK, not per page.** A stack is one DOM container
      of sibling panels (the structures tab, the sweep pane, …), because
      the ordering mechanism is CSS `order:` on a flex column — moving a
      panel into a different container is not something a number can do.
      Up/down across a stack boundary would therefore have moved nothing
      on screen while the button happily reported success, which is the
      "control whose only result renders below the fold" bug again.

    * **Reordering is server-authoritative.** The drag hook pushes
      `layout_drop` and the server re-renders the `order:` styles; the
      client never moves a node. LiveView's DOM patching re-sorts a
      container's children to match the server's markup on the next
      patch, so a client-side move would have silently snapped back the
      moment any row updated — and these pages tick every 30s.

    * **Unknown keys are dropped, missing keys are re-inserted at their
      DEFAULT position.** localStorage is user-writable and a deploy can
      add a board; a stored order is a preference, never the schema.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  @enforce_keys [:store, :defaults, :order]
  defstruct [:store, :defaults, :order, collapsed: MapSet.new()]

  @type stack :: String.t()
  @type key :: String.t()
  @type t :: %__MODULE__{
          store: String.t(),
          defaults: %{stack => [key]},
          order: %{stack => [key]},
          collapsed: MapSet.t()
        }

  @doc """
  A fresh layout: `store` is the localStorage key this page persists
  under, `stacks` the default order of every panel, grouped by the DOM
  container they are siblings in.
  """
  @spec new(String.t(), %{stack => [key]}) :: t()
  def new(store, stacks) when is_binary(store) and is_map(stacks) do
    %__MODULE__{store: store, defaults: stacks, order: stacks}
  end

  @doc "The `ls_update_<store>` event name this layout persists under."
  @spec update_event(t()) :: String.t()
  def update_event(%__MODULE__{store: store}), do: "ls_update_#{store}"

  @doc "The `ls_restore_<store>` event name the browser pushes on mount."
  @spec restore_event(t()) :: String.t()
  def restore_event(%__MODULE__{store: store}), do: "ls_restore_#{store}"

  # -------------------------------------------------------------------
  # Queries used by the templates
  # -------------------------------------------------------------------

  @doc "The CSS `order` value for one panel, as a style attribute."
  @spec style(t() | nil, key | nil) :: String.t() | nil
  def style(nil, _key), do: nil
  def style(_layout, nil), do: nil

  def style(%__MODULE__{} = layout, key) do
    case index(layout, key) do
      nil -> nil
      idx -> "order:#{idx}"
    end
  end

  @doc "Position of `key` inside its stack, or `nil` if this page does not own it."
  @spec index(t(), key) :: non_neg_integer() | nil
  def index(%__MODULE__{order: order}, key) do
    Enum.find_value(order, fn {_stack, keys} ->
      case Enum.find_index(keys, &(&1 == key)) do
        nil -> nil
        idx -> idx
      end
    end)
  end

  @doc "Is this panel collapsed to its header line?"
  @spec collapsed?(t() | nil, key | nil) :: boolean()
  def collapsed?(nil, _key), do: false
  def collapsed?(_layout, nil), do: false
  def collapsed?(%__MODULE__{collapsed: set}, key), do: MapSet.member?(set, key)

  @doc """
  Can this panel move at all? False for a stack of one, where ▲/▼ would
  be two buttons that provably do nothing.
  """
  @spec movable?(t() | nil, key | nil) :: boolean()
  def movable?(nil, _key), do: false
  def movable?(_layout, nil), do: false

  def movable?(%__MODULE__{} = layout, key) do
    case stack_keys(layout, key) do
      nil -> false
      keys -> length(keys) > 1
    end
  end

  @doc "Already at the top of its stack."
  @spec first?(t(), key) :: boolean()
  def first?(%__MODULE__{} = layout, key), do: index(layout, key) == 0

  @doc "Already at the bottom of its stack."
  @spec last?(t(), key) :: boolean()
  def last?(%__MODULE__{} = layout, key) do
    case stack_keys(layout, key) do
      nil -> true
      keys -> index(layout, key) == length(keys) - 1
    end
  end

  @doc "True when anything at all has been moved or collapsed."
  @spec customised?(t()) :: boolean()
  def customised?(%__MODULE__{} = layout),
    do: layout.order != layout.defaults or MapSet.size(layout.collapsed) > 0

  # -------------------------------------------------------------------
  # Mutations
  # -------------------------------------------------------------------

  @doc "Open a collapsed panel, collapse an open one."
  @spec toggle(t(), key) :: t()
  def toggle(%__MODULE__{collapsed: set} = layout, key) do
    set = if MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key)
    %{layout | collapsed: set}
  end

  @doc "Every panel on the page, collapsed or expanded in one click."
  @spec collapse_all(t(), boolean()) :: t()
  def collapse_all(%__MODULE__{} = layout, true) do
    %{layout | collapsed: layout.order |> Map.values() |> List.flatten() |> MapSet.new()}
  end

  def collapse_all(%__MODULE__{} = layout, false), do: %{layout | collapsed: MapSet.new()}

  @doc "Back to the order the template ships, everything open."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = layout),
    do: %{layout | order: layout.defaults, collapsed: MapSet.new()}

  @doc "One step up or down inside the panel's own stack."
  @spec move(t(), key, String.t()) :: t()
  def move(%__MODULE__{} = layout, key, direction) when direction in ["up", "down"] do
    with stack when not is_nil(stack) <- stack_of(layout, key),
         keys <- Map.fetch!(layout.order, stack),
         idx when not is_nil(idx) <- Enum.find_index(keys, &(&1 == key)) do
      target = if direction == "up", do: idx - 1, else: idx + 1

      if target in 0..(length(keys) - 1)//1 do
        put_in(layout.order[stack], swap(keys, idx, target))
      else
        layout
      end
    else
      _ -> layout
    end
  end

  def move(%__MODULE__{} = layout, _key, _direction), do: layout

  @doc """
  Drag-and-drop: put `key` immediately before or after `target`.

  A drop onto another stack is refused rather than rehomed — the two
  stacks are different containers, and a panel cannot leave its own.
  """
  @spec drop(t(), key, key, String.t()) :: t()
  def drop(%__MODULE__{} = layout, key, target, position)
      when position in ["before", "after"] do
    stack = stack_of(layout, key)

    cond do
      key == target -> layout
      is_nil(stack) -> layout
      stack != stack_of(layout, target) -> layout
      true -> put_in(layout.order[stack], reinsert(layout.order[stack], key, target, position))
    end
  end

  def drop(%__MODULE__{} = layout, _key, _target, _position), do: layout

  # -------------------------------------------------------------------
  # Persistence
  # -------------------------------------------------------------------

  @doc "The blob written to localStorage."
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = layout) do
    Jason.encode!(%{
      "order" => layout.order,
      "collapsed" => MapSet.to_list(layout.collapsed)
    })
  end

  @doc """
  Re-validate a stored blob onto this page's own panel set.

  Everything here came from localStorage, so nothing is trusted: a key
  this build no longer renders is dropped, a key this build added is
  re-inserted where the template puts it, and a blob of any other shape
  leaves the defaults alone.
  """
  @spec restore(t(), String.t() | nil) :: t()
  def restore(%__MODULE__{} = layout, value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = stored} -> apply_stored(layout, stored)
      _ -> layout
    end
  end

  def restore(%__MODULE__{} = layout, _value), do: layout

  defp apply_stored(layout, stored) do
    known = layout.defaults |> Map.values() |> List.flatten() |> MapSet.new()

    order =
      Map.new(layout.defaults, fn {stack, default_keys} ->
        {stack, merge_order(default_keys, stored_stack(stored, stack))}
      end)

    collapsed =
      stored
      |> Map.get("collapsed", [])
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and MapSet.member?(known, &1)))
      |> MapSet.new()

    %{layout | order: order, collapsed: collapsed}
  end

  defp stored_stack(stored, stack) do
    case stored do
      %{"order" => %{^stack => keys}} when is_list(keys) -> Enum.filter(keys, &is_binary/1)
      _ -> []
    end
  end

  # Stored order wins for the keys it names; a key it does not name is
  # re-inserted after the default-order neighbour that precedes it, so a
  # board added above "Now" by a deploy lands above "Now", not at the
  # bottom of a reader's saved stack.
  defp merge_order(defaults, stored) do
    kept = Enum.filter(stored, &(&1 in defaults)) |> Enum.uniq()

    defaults
    |> Enum.reject(&(&1 in kept))
    |> Enum.reduce(kept, fn missing, acc ->
      insert_near_default(acc, defaults, missing)
    end)
  end

  defp insert_near_default(acc, defaults, missing) do
    preceding =
      defaults
      |> Enum.take_while(&(&1 != missing))
      |> Enum.reverse()
      |> Enum.find(&(&1 in acc))

    case preceding && Enum.find_index(acc, &(&1 == preceding)) do
      nil -> [missing | acc]
      idx -> List.insert_at(acc, idx + 1, missing)
    end
  end

  # -------------------------------------------------------------------
  # LiveView glue
  # -------------------------------------------------------------------

  @doc """
  Put a layout on the socket as `@panel_layout`. Call once in `mount/3`;
  the browser's stored copy arrives later, through `handle_restore/2`.

  NOT `@layout`: that assign is Phoenix's own, naming the page layout
  template, and overwriting it raises
  `:layout accepts a tuple of the form {LayoutModule, "template"}` on
  the first render of the page -- at runtime only, which is why every
  scout page has an integration test that merely opens it.
  """
  @spec assign_layout(Phoenix.LiveView.Socket.t(), String.t(), %{stack => [key]}) ::
          Phoenix.LiveView.Socket.t()
  def assign_layout(socket, store, stacks),
    do: assign(socket, :panel_layout, new(store, stacks))

  @doc """
  Handle one `layout_*` event from `panel/1`'s controls.

  Every page wires this with a single catch-all clause: the events are
  the component's, not the page's, and a page that forgot one would
  render buttons that raise.
  """
  @spec handle(Phoenix.LiveView.Socket.t(), String.t(), map()) :: Phoenix.LiveView.Socket.t()
  def handle(socket, event, params) do
    layout = socket.assigns.panel_layout
    key = Map.get(params, "key")

    layout =
      case event do
        "layout_toggle" when is_binary(key) ->
          toggle(layout, key)

        "layout_move" when is_binary(key) ->
          move(layout, key, Map.get(params, "dir"))

        "layout_drop" when is_binary(key) ->
          drop(layout, key, Map.get(params, "target"), Map.get(params, "position"))

        "layout_collapse_all" ->
          collapse_all(layout, true)

        "layout_expand_all" ->
          collapse_all(layout, false)

        "layout_reset" ->
          reset(layout)

        _ ->
          layout
      end

    socket
    |> assign(:panel_layout, layout)
    |> persist()
  end

  @doc "The browser's stored blob, pushed once on mount."
  @spec handle_restore(Phoenix.LiveView.Socket.t(), String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def handle_restore(socket, value),
    do: assign(socket, :panel_layout, restore(socket.assigns.panel_layout, value))

  defp persist(socket) do
    layout = socket.assigns.panel_layout
    push_event(socket, update_event(layout), %{value: encode(layout)})
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp stack_of(%__MODULE__{order: order}, key) do
    Enum.find_value(order, fn {stack, keys} -> if key in keys, do: stack end)
  end

  defp stack_keys(%__MODULE__{order: order} = layout, key) do
    case stack_of(layout, key) do
      nil -> nil
      stack -> Map.fetch!(order, stack)
    end
  end

  defp swap(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)

    list
    |> List.replace_at(i, b)
    |> List.replace_at(j, a)
  end

  defp reinsert(keys, key, target, position) do
    without = Enum.reject(keys, &(&1 == key))

    case Enum.find_index(without, &(&1 == target)) do
      nil -> keys
      idx -> List.insert_at(without, if(position == "before", do: idx, else: idx + 1), key)
    end
  end
end
