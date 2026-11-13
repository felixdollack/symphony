defmodule SymphonyElixir.WorkspaceReviewTest do
  use SymphonyElixir.TestSupport

  test "checks out and verifies the pinned pull request commit" do
    root = Path.join(System.tmp_dir!(), "symphony-pr-checkout-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    remote = Path.join([root, "octo", "repo.git"])
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(source)
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    git!(remote, ["init", "--bare"])
    git!(source, ["init"])
    git!(source, ["config", "user.name", "Symphony Test"])
    git!(source, ["config", "user.email", "symphony@example.test"])
    File.write!(Path.join(source, "reviewed.txt"), "pinned revision\n")
    git!(source, ["add", "reviewed.txt"])
    git!(source, ["commit", "-m", "reviewed revision"])
    git!(source, ["remote", "add", "origin", remote])
    git!(source, ["push", "origin", "HEAD:refs/heads/main", "HEAD:refs/pull/21/head"])
    {output, 0} = System.cmd("git", ["--git-dir", remote, "symbolic-ref", "HEAD", "refs/heads/main"])
    assert output == ""
    git!(workspace, ["clone", remote, "."])
    {sha, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])

    issue = %Issue{
      native_ref: %{"repo" => "octo/repo", "number" => 21, "head_sha" => String.trim(sha)}
    }

    assert :ok = Workspace.checkout_review_head(workspace, issue, nil)
    assert {checked_out_sha, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
    assert String.trim(checked_out_sha) == String.trim(sha)
  end

  test "rejects invalid pinned revisions before running Git" do
    issue = %Issue{native_ref: %{"number" => 21, "head_sha" => "21; rm -rf /"}}

    assert {:error, :invalid_pull_request_head} =
             Workspace.checkout_review_head(System.tmp_dir!(), issue, nil)
  end

  defp git!(directory, args) do
    File.mkdir_p!(directory)
    {output, status} = System.cmd("git", ["-C", directory | args], stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{output}"
  end
end
