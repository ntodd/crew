defmodule CrewWeb.GitHubTest do
  @moduledoc "Where things are on github.com."
  use ExUnit.Case, async: true

  alias CrewWeb.GitHub

  @repo %{full_name: "mona/web", default_branch: "main"}

  describe "workflow_url/2" do
    test "a workflow file on the repo's default branch" do
      assert GitHub.workflow_url(@repo, ".github/workflows/ci.yml") ==
               "https://github.com/mona/web/blob/main/.github/workflows/ci.yml"
    end

    test "a branch with a slash stays a path; the rest is escaped" do
      repo = %{@repo | default_branch: "release/1.x#2"}

      assert GitHub.workflow_url(repo, ".github/workflows/ci.yml") ==
               "https://github.com/mona/web/blob/release/1.x%232/.github/workflows/ci.yml"
    end

    test "the file's name is escaped" do
      assert GitHub.workflow_url(@repo, ".github/workflows/ci#linux?x=1%41.yml") ==
               "https://github.com/mona/web/blob/main/.github/workflows/ci%23linux%3Fx%3D1%2541.yml"
    end

    test "a ref after the path is dropped" do
      assert GitHub.workflow_url(@repo, ".github/workflows/ci.yml@refs/heads/main") ==
               "https://github.com/mona/web/blob/main/.github/workflows/ci.yml"
    end

    test "nothing for a path that isn't a workflow file in the repo" do
      assert GitHub.workflow_url(@repo, "dynamic/dependabot/dependabot-updates") == nil
      assert GitHub.workflow_url(@repo, ".github/workflows/../../mix.exs") == nil
      assert GitHub.workflow_url(@repo, "") == nil
      assert GitHub.workflow_url(@repo, nil) == nil
    end
  end

  describe "workflow_file/1" do
    test "the file's path in the repo, or nil" do
      assert GitHub.workflow_file(".github/workflows/ci.yml@refs/heads/main") ==
               ".github/workflows/ci.yml"

      assert GitHub.workflow_file(".github/workflows/ci@nightly.yaml") ==
               ".github/workflows/ci@nightly.yaml"

      assert GitHub.workflow_file("dynamic/copilot-swe-agent/copilot") == nil
      assert GitHub.workflow_file(".github/workflows/sub/ci.yml") == nil
    end
  end
end
