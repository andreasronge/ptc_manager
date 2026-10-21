defmodule PtcManager.Repo.Migrations.RepositoriesCaseInsensitiveIdentity do
  use Ecto.Migration

  # GitHub names are case-insensitive and cluster claims key repositories by
  # their lowercased owner/name, so two rows differing only in case would hide
  # one claim behind the other.
  def change do
    create unique_index(:repositories, ["lower(github_owner)", "lower(github_name)"],
             name: :repositories_github_identity_ci_index
           )
  end
end
