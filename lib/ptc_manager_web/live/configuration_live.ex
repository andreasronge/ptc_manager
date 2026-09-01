defmodule PtcManagerWeb.ConfigurationLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.MaintainerActions.Catalog
  alias PtcManager.Operations
  alias PtcManager.Operations.Repository
  alias PtcManager.PromptConfiguration
  alias PtcManager.Repository.Health

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Operations.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Configuration")
     |> assign(:actor, session["actor"] || "maintainer")
     |> load_configuration()}
  end

  @impl true
  def handle_info({:operations_changed, source}, socket)
      when source in [Repository, PtcManager.GitHub.Sync],
      do: {:noreply, load_configuration(socket)}

  def handle_info({:operations_changed, _source}, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "save-prompt",
        %{"action-key" => action_key, "customization" => %{"instructions" => instructions}},
        socket
      ) do
    case PromptConfiguration.save(action_key, instructions, socket.assigns.actor) do
      {:ok, _customization} ->
        {:noreply,
         socket
         |> put_flash(:info, "Prompt instructions saved. New agent starts will use them.")
         |> load_configuration()}

      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Prompt instructions reset to the default.")
         |> load_configuration()}

      {:error, :unknown_action} ->
        {:noreply, put_flash(socket, :error, "That prompt is not configurable.")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, validation_message(changeset))}
    end
  end

  def handle_event("reset-prompt", %{"action-key" => action_key}, socket) do
    if Catalog.configurable_action?(action_key) do
      case PromptConfiguration.reset(action_key) do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, "Prompt instructions reset to the default.")
           |> load_configuration()}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "The prompt could not be reset.")}
      end
    else
      {:noreply, put_flash(socket, :error, "That prompt is not configurable.")}
    end
  end

  defp load_configuration(socket) do
    customizations = Map.new(PromptConfiguration.list(), &{&1.action_key, &1})

    prompts =
      Enum.map(Catalog.configurable_actions(), fn definition ->
        Map.put(definition, :customization, Map.get(customizations, definition.key))
      end)

    repositories = Operations.list_repositories()
    availability = PtcManager.Repository.Checkout.availability(repositories)

    assign(socket,
      prompts: prompts,
      repository_health:
        Enum.map(repositories, &Health.summarize(&1, Map.fetch!(availability, &1.id)))
    )
  end

  def health_classes(:ready), do: "bg-teal-400/15 text-teal-200"
  def health_classes(:attention), do: "bg-amber-400/15 text-amber-200"
  def health_classes(:syncing), do: "bg-sky-400/15 text-sky-200"
  def health_classes(:unchecked), do: "bg-white/5 text-slate-400"

  def health_detail(%{detail: %DateTime{} = value}), do: Calendar.strftime(value, "%d %b · %H:%M")
  def health_detail(%{detail: nil}), do: "No detail recorded."
  def health_detail(%{detail: detail}), do: detail

  defp validation_message(%Ecto.Changeset{} = changeset) do
    case changeset.errors do
      [{:instructions, {_message, metadata}} | _rest] ->
        if metadata[:validation] == :length,
          do: "Prompt instructions must be 20,000 characters or fewer.",
          else: "Prompt instructions could not be saved."

      _errors ->
        "Prompt instructions could not be saved."
    end
  end

  defp validation_message(_reason), do: "Prompt instructions could not be saved."
end
