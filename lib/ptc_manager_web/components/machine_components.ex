defmodule PtcManagerWeb.MachineComponents do
  @moduledoc """
  Renders a machine's tool inventory per execution context.

  The input is `PtcManager.Machine.ToolInventory.summary/3`, the same
  JSON-shaped map a peer's status document carries, so this console and the
  Cluster page render local and remote machines alike.
  """

  use PtcManagerWeb, :html

  attr :id, :string, required: true
  attr :inventory, :map, required: true, doc: "context => nil | summary map"
  attr :now, :any, required: true

  def tool_inventory(assigns) do
    assigns = assign(assigns, :tools, tool_names(assigns.inventory))

    ~H"""
    <div id={@id} class="overflow-x-auto">
      <table class="w-full min-w-[28rem] text-left text-sm">
        <thead class="text-xs uppercase tracking-wide text-slate-500">
          <tr>
            <th class="py-2 pr-4 font-semibold">Tool</th>
            <th :for={{context, summary} <- contexts(@inventory)} class="py-2 pr-4 font-semibold">
              {context_label(context)}
              <span class="block text-[11px] font-normal normal-case tracking-normal text-slate-500">
                {context_age(summary, @now)}
              </span>
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-white/5">
          <tr :for={tool <- @tools} id={"#{@id}-#{tool}"}>
            <td class="py-2 pr-4 font-mono text-xs text-slate-300">{tool}</td>
            <td :for={{context, summary} <- contexts(@inventory)} class="py-2 pr-4">
              <.tool_cell
                id={"#{@id}-#{tool}-#{context}"}
                tool={summary && get_in(summary, ["tools", tool])}
                stale={stale?(summary, @now)}
              />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :tool, :map, default: nil
  attr :stale, :boolean, default: false

  defp tool_cell(assigns) do
    ~H"""
    <span id={@id} title={@tool && @tool["detail"]} class={["text-xs", cell_class(@tool, @stale)]}>
      {cell_text(@tool)}
    </span>
    """
  end

  defp contexts(inventory), do: Enum.sort_by(inventory, fn {context, _} -> context end)

  defp tool_names(inventory) do
    inventory
    |> Map.values()
    |> Enum.flat_map(fn
      %{"tools" => tools} when is_map(tools) -> Map.keys(tools)
      _none -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def context_label("pane"), do: "Agent panes"
  def context_label("setup"), do: "Workspace setup"
  def context_label(context), do: context

  defp context_age(nil, _now), do: "not probed yet"

  defp context_age(%{"captured_at" => captured_at} = summary, now) do
    age =
      case DateTime.from_iso8601(to_string(captured_at)) do
        {:ok, at, _offset} -> TimeFormat.relative(now, at)
        _invalid -> "unknown"
      end

    if stale?(summary, now), do: "stale · #{age}", else: age
  end

  # A summary may have been cached, by this console or a peer, past the age
  # limit since it was built, so staleness is judged now, from its capture time.
  defp stale?(nil, _now), do: false

  defp stale?(%{"captured_at" => captured_at} = summary, now) do
    case DateTime.from_iso8601(to_string(captured_at)) do
      {:ok, at, _offset} ->
        summary["stale"] == true or
          DateTime.diff(now, at, :millisecond) > PtcManager.Machine.ToolInventory.max_age_ms()

      _invalid ->
        true
    end
  end

  defp cell_text(nil), do: "—"
  defp cell_text(%{"status" => "ok", "version" => version}) when is_binary(version), do: version
  defp cell_text(%{"status" => "ok"}), do: "present"
  defp cell_text(%{"status" => "failed"}), do: "fails"
  defp cell_text(%{"status" => "timed_out"}), do: "timed out"
  defp cell_text(%{"status" => "not_probed"}), do: "not probed"
  defp cell_text(%{"status" => status}), do: status

  defp cell_class(_tool, true), do: "text-amber-300"
  defp cell_class(%{"status" => "ok"}, _stale), do: "text-teal-300"
  defp cell_class(%{"status" => "missing"}, _stale), do: "text-slate-500"
  defp cell_class(nil, _stale), do: "text-slate-500"
  defp cell_class(_tool, _stale), do: "text-rose-300"
end
