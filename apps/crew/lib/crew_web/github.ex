defmodule CrewWeb.GitHub do
  @moduledoc "Where things are on github.com: a repo, its PRs, commits, branches and runs."

  @base "https://github.com"

  def repo_url(%{full_name: full_name}), do: "#{@base}/#{full_name}"
  def pr_url(repo, number), do: "#{repo_url(repo)}/pull/#{number}"
  def commit_url(repo, sha), do: "#{repo_url(repo)}/commit/#{sha}"

  # Slashes stay (feat/a is a path GitHub reads as the branch); the
  # rest of what a branch may hold is escaped.
  def branch_url(repo, branch),
    do:
      "#{repo_url(repo)}/tree/#{URI.encode(branch || "", &(URI.char_unreserved?(&1) or &1 == ?/))}"

  def run_url(%{repo: repo, github_run_id: id, run_attempt: n}),
    do: "#{repo_url(repo)}/actions/runs/#{id}/attempts/#{n}"
end
