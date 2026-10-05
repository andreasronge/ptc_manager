defmodule PtcManagerWeb.BranchFilter do
  @moduledoc """
  The Planning and Delivery filter by the branch work targets: all of it, only
  default-branch work, or one integration branch. The choice is a `branch`
  URL parameter, remembered per viewer in the browser like the repository one.
  """

  use Phoenix.Component

  alias PtcManager.Repository.IntegrationBranches

  @doc "The selected filter from URL parameters: nil (all), :default, or a branch name."
  def from_params(%{"branch" => "default"}), do: :default
  def from_params(%{"branch" => "all"}), do: nil

  def from_params(%{"branch" => branch}) when is_binary(branch) and branch != "",
    do: branch

  def from_params(_params), do: nil

  @doc "Every integration branch a repository maps a label to, for the selector."
  def branches(repositories) do
    repositories
    |> Enum.flat_map(&IntegrationBranches.list/1)
    |> Enum.map(& &1["branch"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Keeps the items whose base matches. `base_of` returns an item's base and its
  repository's default branch.
  """
  def apply(items, nil, _base_of), do: items

  def apply(items, :default, base_of) do
    Enum.filter(items, fn item ->
      {base, default} = base_of.(item)
      base == default
    end)
  end

  def apply(items, branch, base_of) when is_binary(branch),
    do: Enum.filter(items, &(elem(base_of.(&1), 0) == branch))

  attr :branches, :list, required: true
  attr :selected, :any, default: nil

  # A selection whose mapping is gone stays listed, so it can be cleared.
  def branch_selector(assigns) do
    assigns =
      assign(
        assigns,
        :options,
        if(is_binary(assigns.selected) and assigns.selected not in assigns.branches,
          do: assigns.branches ++ [assigns.selected],
          else: assigns.branches
        )
      )

    ~H"""
    <label
      :if={@options != [] or @selected == :default}
      class="flex items-center gap-2 text-xs font-medium text-slate-500"
    >
      Branch
      <select
        id="branch-selector"
        data-branch-selector
        onchange="window.ptcSelectBranch(this.value)"
        class="max-w-[16rem] rounded-lg border border-white/10 bg-slate-900 px-3 py-1.5 text-sm text-slate-200"
      >
        <option value="all" selected={is_nil(@selected)}>All branches</option>
        <option value="default" selected={@selected == :default}>Default branches</option>
        <option :for={branch <- @options} value={branch} selected={@selected == branch}>
          {branch}
        </option>
      </select>
    </label>
    """
  end
end
