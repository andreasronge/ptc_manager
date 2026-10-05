defmodule PtcManagerWeb.RepositoryDisplay do
  @moduledoc "Labels and colours for repository synchronization and health checks."

  def sync_label(%{sync_status: "syncing"}), do: "syncing"
  def sync_label(%{sync_status: "ok"}), do: "connected"
  def sync_label(%{sync_status: "error"}), do: "needs attention"
  def sync_label(_repository), do: "not synchronized"

  def sync_classes(%{sync_status: "ok"}), do: "text-teal-300"
  def sync_classes(%{sync_status: "error"}), do: "text-rose-300"
  def sync_classes(_repository), do: "text-amber-300"

  def health_classes(:ready), do: "bg-teal-400/15 text-teal-200"
  def health_classes(:attention), do: "bg-amber-400/15 text-amber-200"
  def health_classes(:syncing), do: "bg-sky-400/15 text-sky-200"
  def health_classes(:unchecked), do: "bg-white/5 text-slate-400"

  def health_detail(%{detail: %DateTime{} = value}), do: Calendar.strftime(value, "%d %b · %H:%M")
  def health_detail(%{detail: nil}), do: "No detail recorded."
  def health_detail(%{detail: detail}), do: detail

  def full_name(repository), do: "#{repository.github_owner}/#{repository.github_name}"
end
