defmodule PtcManager.Operations.Repository do
  use Ecto.Schema
  import Ecto.Changeset

  alias PtcManager.Repository.MaintainerLabels

  schema "repositories" do
    field :github_owner, :string
    field :github_name, :string
    field :default_branch, :string, default: "main"
    field :github_default_branch, :string
    field :integration_branches, :map, default: %{"mappings" => []}
    field :github_branch_names, :map, default: %{"names" => []}
    field :branch_prefixes, :map, default: %{"default" => "ptc-manager/", "mappings" => []}
    field :github_branches_checked_at, :utc_datetime_usec
    field :workspace_setup_command, :string
    field :workspace_setup_timeout_minutes, :integer
    field :enabled, :boolean, default: true
    field :auto_fix_issues, :boolean, default: false
    field :auto_fix_daily_limit, :integer, default: 5
    field :local_path, :string
    field :sync_status, :string, default: "never"
    field :last_synced_at, :utc_datetime_usec
    field :last_sync_error, :string
    field :github_viewer_login, :string
    field :maintainer_labels, :map, default: %{"labels" => []}
    field :github_label_names, :map, default: %{"names" => []}
    field :github_labels_checked_at, :utc_datetime_usec
    field :required_pre_pr_reviews, :integer, default: 2

    has_many :issues, PtcManager.Operations.Issue
    has_many :jobs, PtcManager.Operations.Job
    has_many :agent_actions, PtcManager.Operations.AgentAction
    has_many :resource_operations, PtcManager.Operations.ResourceOperation
    has_many :pr_publications, PtcManager.Operations.PrPublication
    has_many :automation_definitions, PtcManager.Automations.Definition
    has_many :deployments, PtcManager.Deployments.Deployment
    has_many :agent_environment_variables, PtcManager.Operations.AgentEnvironmentVariable

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Longest workspace setup command and timeout a repository may configure."
  def max_workspace_setup_command_bytes, do: 2_000
  def max_workspace_setup_timeout_minutes, do: 24 * 60

  def changeset(repository, attrs) do
    repository
    |> cast(attrs, [
      :github_owner,
      :github_name,
      :default_branch,
      :github_default_branch,
      :workspace_setup_command,
      :workspace_setup_timeout_minutes,
      :integration_branches,
      :github_branch_names,
      :github_branches_checked_at,
      :branch_prefixes,
      :enabled,
      :auto_fix_issues,
      :auto_fix_daily_limit,
      :local_path,
      :sync_status,
      :last_synced_at,
      :last_sync_error,
      :github_viewer_login,
      :maintainer_labels,
      :github_label_names,
      :github_labels_checked_at,
      :required_pre_pr_reviews
    ])
    |> validate_required([:github_owner, :github_name, :default_branch, :enabled])
    |> validate_inclusion(:sync_status, ["never", "syncing", "ok", "error"])
    |> validate_change(:default_branch, fn :default_branch, branch ->
      if PtcManager.GitHub.Ref.safe?(branch),
        do: [],
        else: [default_branch: "is not a safe branch name"]
    end)
    |> MaintainerLabels.validate()
    |> PtcManager.Repository.IntegrationBranches.validate()
    |> PtcManager.Repository.BranchPrefixes.validate()
    |> validate_number(:required_pre_pr_reviews,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 3
    )
    |> validate_workspace_setup()
    |> validate_number(:auto_fix_daily_limit,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 50
    )
    |> validate_change(:local_path, fn :local_path, path ->
      if Path.type(path) == :absolute,
        do: [],
        else: [local_path: "must be an absolute path"]
    end)
    |> update_change(:local_path, &normalize_local_path/1)
    |> unique_constraint([:github_owner, :github_name])
    |> unique_constraint(:local_path)
  end

  defp normalize_local_path(path) when is_binary(path) and path != "", do: Path.expand(path)
  defp normalize_local_path(path), do: path

  # The command runs through /bin/sh -c in a fresh worktree, so it is one line;
  # a command and its timeout are set together or not at all.
  defp validate_workspace_setup(changeset) do
    command = get_field(changeset, :workspace_setup_command)
    timeout = get_field(changeset, :workspace_setup_timeout_minutes)

    cond do
      is_nil(command) and is_nil(timeout) ->
        changeset

      not is_binary(command) or String.trim(command) != command or command == "" or
        byte_size(command) > max_workspace_setup_command_bytes() or
          String.contains?(command, ["\n", "\r", <<0>>]) ->
        add_error(changeset, :workspace_setup_command, "must be one non-blank line")

      not is_integer(timeout) or timeout < 1 or timeout > max_workspace_setup_timeout_minutes() ->
        add_error(changeset, :workspace_setup_timeout_minutes, "must be 1 to 1440 minutes")

      true ->
        changeset
    end
  end
end
