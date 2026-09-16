defmodule PtcManagerWeb.DailyDigestLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.DailyDigests
  alias PtcManager.Operations

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: PtcManager.Operations.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Updates")
     |> assign(:selected_repository, nil)
     |> assign(:repositories, Operations.list_repositories())
     |> assign(:selected_digest, nil)
     |> load_digests()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    repositories = Operations.list_repositories()

    selected =
      case params["repo"] do
        key when is_binary(key) ->
          if Enum.any?(repositories, &(repository_key(&1) == key)), do: key, else: nil

        _key ->
          nil
      end

    socket =
      socket
      |> assign(:repositories, repositories)
      |> assign(:selected_repository, selected)
      |> assign(:selected_digest, nil)
      |> assign(:page_title, "Updates")
      |> load_digests()

    case params["id"] do
      id when is_binary(id) ->
        selected_digest =
          with {digest_id, ""} <- Integer.parse(id) do
            Enum.find(socket.assigns.digests, &(&1.id == digest_id))
          else
            _invalid -> nil
          end

        if selected_digest do
          {:noreply,
           socket
           |> assign(:selected_digest, selected_digest)
           |> assign(:page_title, selected_digest.title || "Daily update")}
        else
          target =
            if selected,
              do: "/updates?repo=#{URI.encode_www_form(selected)}",
              else: ~p"/updates"

          {:noreply,
           socket
           |> put_flash(:error, "That daily update is not available.")
           |> push_navigate(to: target)}
        end

      _id ->
        {:noreply, socket}
    end
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

  def markdown_html(markdown, opts \\ [])

  def markdown_html(markdown, opts) when is_binary(markdown) do
    markdown
    |> MDEx.to_html!(
      extension: [table: true, strikethrough: true, autolink: Keyword.get(opts, :autolink, true)],
      render: [unsafe: true],
      sanitize: MDEx.Document.default_sanitize_options()
    )
    |> Phoenix.HTML.raw()
  end

  def markdown_html(_markdown, _opts), do: Phoenix.HTML.raw("")

  def digest_date(date), do: Calendar.strftime(date, "%A, %d %B %Y")

  def short_date(date), do: Calendar.strftime(date, "%d %b")

  def status(digest), do: DailyDigests.status(digest)

  def status_label(%{published_at: %DateTime{}, change_count: 0}), do: "Quiet day"
  def status_label(%{published_at: %DateTime{}}), do: "Published"
  def status_label(%{agent_action: %{state: "running"}}), do: "Writing now"
  def status_label(%{agent_action: %{state: "sync_pending"}}), do: "Saving"
  def status_label(%{agent_action: %{state: "failed"}}), do: "Generation failed"
  def status_label(%{agent_action: %{state: "cancelled"}}), do: "Generation cancelled"
  def status_label(_digest), do: "Queued"

  def status_detail(digest) do
    case status(digest) do
      "cancelled" ->
        "This update was cancelled. Its record is retained in Operations."

      "failed" ->
        "The retained agent output can be inspected from Operations."

      _ ->
        "This page will update automatically when PtcManager has validated and rendered the agent's structured report."
    end
  end

  def status_classes(digest) do
    case status(digest) do
      "published" -> "bg-teal-400/15 text-teal-300 ring-teal-400/20"
      "failed" -> "bg-rose-400/15 text-rose-300 ring-rose-400/20"
      "cancelled" -> "bg-slate-400/15 text-slate-300 ring-slate-400/20"
      "running" -> "bg-sky-400/15 text-sky-300 ring-sky-400/20"
      "sync_pending" -> "bg-violet-400/15 text-violet-300 ring-violet-400/20"
      _state -> "bg-amber-400/15 text-amber-300 ring-amber-400/20"
    end
  end

  def source_short(%{source_head_sha: sha}) when is_binary(sha), do: String.slice(sha, 0, 10)
  def source_short(_digest), do: nil

  def evidence_hash(%{agent_action: %{target_snapshot: snapshot}}) when is_map(snapshot),
    do: snapshot["trusted_evidence_sha256"]

  def evidence_hash(_digest), do: nil

  def pull_request_numbers(digest),
    do: get_in(digest.pull_request_numbers || %{}, ["numbers"]) || []

  defp load_digests(socket) do
    digests =
      case socket.assigns.selected_repository do
        nil -> DailyDigests.list_digests()
        key -> Enum.filter(DailyDigests.list_digests(), &(repository_key(&1.repository) == key))
      end

    assign(socket, :digests, digests)
  end

  defp repository_key(repository), do: "#{repository.github_owner}/#{repository.github_name}"
end
