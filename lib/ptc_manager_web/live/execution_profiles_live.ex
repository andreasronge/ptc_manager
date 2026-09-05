defmodule PtcManagerWeb.ExecutionProfilesLive do
  use PtcManagerWeb, :live_view
  alias PtcManager.ExecutionProfiles

  def mount(_, session, socket) do
    {:ok,
     assign(socket,
       page_title: "Execution profiles",
       actor: session["actor"] || "maintainer",
       profiles: ExecutionProfiles.list(),
       catalogs: %{},
       refreshing: false
     )}
  end

  def handle_event("change", %{"profile" => params}, socket) do
    profiles =
      Enum.map(socket.assigns.profiles, fn profile ->
        if profile.name == params["name"],
          do:
            profile
            |> PtcManager.ExecutionProfiles.Profile.changeset(params)
            |> Ecto.Changeset.apply_changes(),
          else: profile
      end)

    {:noreply, assign(socket, :profiles, profiles)}
  end

  def handle_event("save", %{"profile" => params}, socket) do
    case ExecutionProfiles.save(params["name"], params, socket.assigns.actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:profiles, ExecutionProfiles.list())
         |> put_flash(:info, "Profile saved. Existing jobs keep their approved settings.")}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, "Check the agent, model, effort and review limit (0–5).")}
    end
  end

  def handle_event("refresh-models", _, socket) do
    adapter = Application.get_env(:ptc_manager, :review_adapter, PtcManager.Reviews.Adapter)

    {:noreply,
     socket
     |> assign(:refreshing, true)
     |> start_async(:models, fn ->
       Map.new(~w(codex claude cursor), fn kind -> {kind, adapter.models(kind)} end)
     end)}
  end

  def handle_async(:models, {:ok, catalogs}, socket),
    do: {:noreply, assign(socket, catalogs: catalogs, refreshing: false)}

  def handle_async(:models, {:exit, _}, socket),
    do:
      {:noreply,
       socket
       |> assign(:refreshing, false)
       |> put_flash(:error, "Model discovery failed; saved profiles are unchanged.")}

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path="/configuration">
      <div class="mx-auto max-w-5xl space-y-6 p-6 text-slate-200">
        <h1 class="text-2xl font-semibold text-white">Execution profiles</h1>
        <p>
          Small scope and low risk suggests Small. Large scope or high risk suggests Strong. Everything else suggests Standard. You can override the suggestion before starting.
        </p>
        <button
          phx-click="refresh-models"
          disabled={@refreshing}
          class="rounded bg-teal-300 px-4 py-2 text-slate-950"
        >
          {if @refreshing, do: "Checking worker accounts…", else: "Refresh available models"}
        </button>
        <div :for={{kind, result} <- @catalogs} class="rounded border border-white/10 p-3">
          <h2 class="font-semibold">{String.capitalize(kind)}</h2>
          <%= case result do %>
            <% {:ok, catalog} -> %>
              <p class="text-sm">
                {catalog["note"] ||
                  "Reported by the worker account on the last refresh. Launch failures are shown for unavailable models."}
              </p>
              <details>
                <summary>Available model IDs</summary>
                <ul class="max-h-56 overflow-auto text-sm">
                  <li :for={model <- catalog["models"]}>{model["id"]} — {model["name"]}</li>
                </ul>
              </details>
            <% _ -> %>
              <p>Discovery unavailable. Check the worker login; saved models have not changed.</p>
          <% end %>
        </div>
        <div class="grid gap-5 md:grid-cols-3">
          <.form
            :for={profile <- @profiles}
            for={%{}}
            as={:profile}
            id={"profile-#{profile.name}"}
            phx-submit="save"
            phx-change="change"
            class="space-y-3 rounded-xl border border-white/10 bg-white/5 p-5"
          >
            <h2 class="text-xl font-semibold">{String.capitalize(profile.name)}</h2>
            <input type="hidden" name="profile[name]" value={profile.name} />
            <label class="block">
              Implementation agent<select name="profile[kind]" class="block w-full bg-slate-900"><option
                  :for={kind <- ~w(codex claude cursor)}
                  value={kind}
                  selected={kind == profile.kind}
                >{kind}</option></select>
            </label>
            <label class="block">
              Model<input
                name="profile[model]"
                value={profile.model}
                required
                list={"models-#{profile.kind}"}
                class="block w-full bg-slate-900"
              />
            </label>
            <label class="block">
              Reasoning effort<select name="profile[effort]" class="block w-full bg-slate-900"><option value="">Model default</option><option
                  :for={effort <- PtcManager.ExecutionProfiles.Profile.efforts(profile.kind)}
                  value={effort}
                  selected={effort == profile.effort}
                >{effort}</option></select>
            </label>
            <label class="block">
              Reviewer agent<select name="profile[reviewer_kind]" class="block w-full bg-slate-900"><option
                  :for={kind <- ~w(codex claude cursor)}
                  value={kind}
                  selected={kind == profile.reviewer_kind}
                >{kind}</option></select>
            </label>
            <label class="block">
              Reviewer model<input
                name="profile[reviewer_model]"
                value={profile.reviewer_model}
                required
                list={"models-#{profile.reviewer_kind}"}
                class="block w-full bg-slate-900"
              />
            </label>
            <label class="block">
              Reviewer effort<select name="profile[reviewer_effort]" class="block w-full bg-slate-900"><option value="">Model default</option><option
                  :for={effort <- PtcManager.ExecutionProfiles.Profile.efforts(profile.reviewer_kind)}
                  value={effort}
                  selected={effort == profile.reviewer_effort}
                >{effort}</option></select>
            </label>
            <label class="block">
              Maximum reviews<input
                type="number"
                min="0"
                max="5"
                name="profile[max_reviews]"
                value={profile.max_reviews}
                class="block w-full bg-slate-900"
              />
            </label>
            <button class="rounded bg-teal-300 px-3 py-2 text-slate-950">
              Save {String.capitalize(profile.name)}
            </button>
          </.form>
        </div>
        <datalist :for={{kind, {:ok, catalog}} <- @catalogs} id={"models-#{kind}"}>
          <option :for={model <- catalog["models"]} value={model["id"]}>{model["name"]}</option>
        </datalist>
        <p class="text-sm text-slate-400">
          Model IDs belong to each agent's account. Unsupported models fail visibly; PtcManager never silently changes provider or model. For Cursor, choose the effort-specific model ID.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
