defmodule CrewWeb.GitHub do
  @moduledoc "Where things are on github.com: a repo, its PRs, commits, branches, runs and workflow files."

  @base "https://github.com"

  def repo_url(%{full_name: full_name}), do: "#{@base}/#{full_name}"
  def pr_url(repo, number), do: "#{repo_url(repo)}/pull/#{number}"
  def commit_url(repo, sha), do: "#{repo_url(repo)}/commit/#{sha}"

  def branch_url(repo, branch), do: "#{repo_url(repo)}/tree/#{escape(branch || "")}"

  def run_url(%{repo: repo, github_run_id: id, run_attempt: n}),
    do: "#{repo_url(repo)}/actions/runs/#{id}/attempts/#{n}"

  @doc """
  A run's workflow file on the repo's default branch, from GitHub's
  `path`; nil unless it's a file in `.github/workflows/`.
  """
  def workflow_url(repo, path) do
    case workflow_file(path) do
      nil ->
        nil

      file ->
        "#{repo_url(repo)}/blob/#{escape(Map.get(repo, :default_branch) || "HEAD")}/#{escape(file)}"
    end
  end

  @doc """
  The workflow file in GitHub's `path`, without a ref after it; nil for
  one GitHub runs itself (`dynamic/...`), which isn't in the repo.
  GitHub only reads workflows directly in `.github/workflows/`, and a
  file's name may hold an `@` of its own.
  """
  def workflow_file(path) when is_binary(path) do
    case Regex.run(~r{\A(\.github/workflows/[^/]+?\.ya?ml)(?:@.+)?\z}, path) do
      [_, file] -> file
      nil -> nil
    end
  end

  def workflow_file(_path), do: nil

  # Slashes stay (feat/a is a path GitHub reads as the branch, and a
  # file's directories stay directories); the rest is escaped.
  defp escape(path), do: URI.encode(path, &(URI.char_unreserved?(&1) or &1 == ?/))
end
