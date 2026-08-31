defmodule PtcManagerWeb.DailyDigestLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.DailyDigests

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: PtcManager.Operations.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Updates")
     |> assign(:schedule_label, schedule_label())
     |> assign(:selected_digest, nil)
     |> load_digests()}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    selected =
      with {digest_id, ""} <- Integer.parse(id) do
        Enum.find(socket.assigns.digests, &(&1.id == digest_id))
      else
        _invalid -> nil
      end

    if selected do
      {:noreply,
       socket
       |> assign(:selected_digest, selected)
       |> assign(:page_title, selected.title || "Daily update")}
    else
      {:noreply,
       socket
       |> put_flash(:error, "That daily update is not available.")
       |> push_navigate(to: ~p"/updates")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:selected_digest, nil)
     |> assign(:page_title, "Updates")}
  end

  @impl true
  def handle_info({:operations_changed, _source}, socket) do
    selected_id = socket.assigns.selected_digest && socket.assigns.selected_digest.id
    socket = load_digests(socket)

    {:noreply,
     assign(
       socket,
       :selected_digest,
       selected_id && Enum.find(socket.assigns.digests, &(&1.id == selected_id))
     )}
  end

  def markdown_html(markdown) when is_binary(markdown) do
    markdown
    |> MDEx.to_html!(
      extension: [table: true, strikethrough: true, autolink: true],
      render: [unsafe: true],
      sanitize: MDEx.Document.default_sanitize_options()
    )
    |> Phoenix.HTML.raw()
  end

  def markdown_html(_markdown), do: Phoenix.HTML.raw("")

  def digest_date(date), do: Calendar.strftime(date, "%A, %d %B %Y")

  def short_date(date), do: Calendar.strftime(date, "%d %b")

  def status(digest), do: DailyDigests.status(digest)

  def status_label(%{published_at: %DateTime{}, change_count: 0}), do: "Quiet day"
  def status_label(%{published_at: %DateTime{}}), do: "Published"
  def status_label(%{agent_action: %{state: "running"}}), do: "Writing now"
  def status_label(%{agent_action: %{state: "sync_pending"}}), do: "Saving"
  def status_label(%{agent_action: %{state: "failed"}}), do: "Generation failed"
  def status_label(_digest), do: "Queued"

  def status_classes(digest) do
    case status(digest) do
      "published" -> "bg-teal-400/15 text-teal-300 ring-teal-400/20"
      "failed" -> "bg-rose-400/15 text-rose-300 ring-rose-400/20"
      "running" -> "bg-sky-400/15 text-sky-300 ring-sky-400/20"
      "sync_pending" -> "bg-violet-400/15 text-violet-300 ring-violet-400/20"
      _state -> "bg-amber-400/15 text-amber-300 ring-amber-400/20"
    end
  end

  def source_short(%{source_head_sha: sha}) when is_binary(sha), do: String.slice(sha, 0, 10)
  def source_short(_digest), do: nil

  def pull_request_numbers(digest),
    do: get_in(digest.pull_request_numbers || %{}, ["numbers"]) || []

  defp load_digests(socket), do: assign(socket, :digests, DailyDigests.list_digests())

  defp schedule_label do
    hour = Application.get_env(:ptc_manager, :daily_digest_hour, 2)
    time_zone = Application.get_env(:ptc_manager, :daily_digest_time_zone, "Europe/Stockholm")
    "Generated after #{hour |> Integer.to_string() |> String.pad_leading(2, "0")}:00 #{time_zone}"
  end
end
