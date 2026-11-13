defmodule SymphonyElixir.GitHub.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Adapter, as: GitHubAdapter
  alias SymphonyElixir.GitHub.AgentTool, as: GitHubAgentTool
  alias SymphonyElixir.GitHub.Client, as: GitHubClient
  alias SymphonyElixir.GitHub.ReviewJob

  defmodule FakeGitHubClient do
    def fetch_issues_by_states(states) do
      send(self(), {:github_states_called, states})
      {:ok, states}
    end

    def fetch_issues_by_ids(ids) do
      send(self(), {:github_ids_called, ids})
      {:ok, ids}
    end
  end

  setup do
    github_client_module = Application.get_env(:symphony_elixir, :github_client_module)

    on_exit(fn ->
      if is_nil(github_client_module) do
        Application.delete_env(:symphony_elixir, :github_client_module)
      else
        Application.put_env(:symphony_elixir, :github_client_module, github_client_module)
      end
    end)

    :ok
  end

  test "adapter validates GitHub config, delegates reads, and advertises github_api" do
    settings = tracker_settings()

    assert :ok = GitHubAdapter.validate_config(settings)

    assert {:error, :missing_github_active_states} =
             GitHubAdapter.validate_config(%{settings | active_states: nil})

    assert {:error, :missing_github_terminal_states} =
             GitHubAdapter.validate_config(%{settings | terminal_states: nil})

    assert :ok = GitHubAdapter.validate_config(%{settings | active_states: [], terminal_states: []})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | active_states: ["Todo"]})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | active_states: [42]})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | active_states: ["closed"]})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | terminal_states: ["open"]})

    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)

    assert {:ok, ["open"]} = GitHubAdapter.fetch_issues_by_states(["open"])
    assert_receive {:github_states_called, ["open"]}

    assert {:ok, ["42"]} = GitHubAdapter.fetch_issues_by_ids(["42"])
    assert_receive {:github_ids_called, ["42"]}

    assert [%{"name" => "github_api"}] = GitHubAdapter.agent_tool_specs()

    assert GitHubAdapter.execute_agent_tool(
             "github_api",
             %{"method" => "GET", "path" => "/user"},
             github_client: fn _method, _path, _params, _body, _opts ->
               {:ok, %{status: 200, body: %{"login" => "octocat"}}}
             end
           )["success"]
  end

  test "client validates repository settings and declares token environments" do
    assert :ok = GitHubClient.validate_settings(tracker_settings())

    assert {:error, :missing_github_repo} =
             GitHubClient.validate_settings(tracker_settings(%{"repo" => 123}))

    assert {:error, :invalid_github_repo} =
             GitHubClient.validate_settings(tracker_settings(%{"repo" => "not-a-repo"}))

    assert {:error, :missing_github_token} =
             GitHubClient.validate_settings(tracker_settings(%{"token" => 123}))

    assert {:error, :invalid_github_api_url} =
             GitHubClient.validate_settings(tracker_settings(%{"api_url" => "not a url"}))

    assert {:error, :invalid_github_api_url} =
             GitHubClient.validate_settings(tracker_settings(%{"api_url" => "http://api.github.com"}))

    assert GitHubClient.secret_environment_names(tracker_settings(%{"token" => "$SYMPHONY_GITHUB_TOKEN"})) == [
             "GITHUB_TOKEN",
             "GH_TOKEN",
             "GITHUB_ENTERPRISE_TOKEN",
             "GH_ENTERPRISE_TOKEN",
             "SYMPHONY_GITHUB_TOKEN"
           ]
  end

  test "client normalizes GitHub issues without dropping provider details" do
    issue = GitHubClient.normalize_issue_for_test(raw_issue(42), "octo/repo")

    assert issue.id == "42"
    assert issue.identifier == "GH-42"

    assert issue.native_ref == %{
             "id" => 1_042,
             "node_id" => "I_42",
             "number" => 42,
             "repo" => "octo/repo",
             "pull_request" => false
           }

    assert issue.title == "Issue 42"
    assert issue.description == "Body 42"
    assert issue.state == "open"
    assert issue.url == "https://github.test/octo/repo/issues/42"
    assert issue.assignee_id == "octocat"
    assert issue.labels == ["bug", "platform"]
    assert issue.blocked_by == []
    assert issue.dispatchable
    assert %DateTime{} = issue.created_at
    assert %DateTime{} = issue.updated_at

    refute GitHubClient.normalize_issue_for_test(
             Map.put(raw_issue(43), "pull_request", %{"url" => "https://api.github.test/pulls/43"}),
             "octo/repo"
           ).dispatchable

    assert GitHubClient.normalize_issue_for_test(
             Map.put(raw_issue(44), "title", " "),
             "octo/repo"
           ) == nil
  end

  test "GitHub pull requests become independent jobs for each review label" do
    issue =
      GitHubClient.normalize_issue_for_test(
        raw_issue(42)
        |> Map.put("pull_request", %{"url" => "https://api.github.test/pulls/42"})
        |> Map.put("labels", [%{"name" => "claude-review"}, %{"name" => "codex-review"}]),
        "octo/repo"
      )
      |> then(&%{&1 | native_ref: Map.put(&1.native_ref, "head_sha", "pinned-sha")})

    assert [%{id: "42@claude-review", agent_profile: :claude} = claude, %{id: "42@codex-review", agent_profile: :codex} = codex] =
             ReviewJob.expand(issue)

    assert claude.identifier == "GH-42-claude-review"
    assert codex.identifier == "GH-42-codex-review"
    assert claude.native_ref["number"] == 42
    assert codex.native_ref["number"] == 42
    assert claude.dispatchable and codex.dispatchable

    assert [%{id: "42@claude-review", agent_profile: :claude}] =
             ReviewJob.select_requested([issue], ["42@claude-review"])

    unlabeled_issue = %{issue | labels: []}

    [active_job] =
      ReviewJob.select_requested(
        [unlabeled_issue],
        ["42@claude-review"]
      )

    refute ReviewJob.routable?(active_job)
  end

  test "GitHub pull requests without review labels are not dispatchable" do
    issue =
      GitHubClient.normalize_issue_for_test(
        raw_issue(42)
        |> Map.put("pull_request", %{"url" => "https://api.github.test/pulls/42"}),
        "octo/repo"
      )

    assert ReviewJob.expand(issue) == []
  end

  test "ReviewJob handles non-PR work items and malformed review identities" do
    regular_issue = %Issue{
      id: "issue-7",
      native_ref: %{"id" => 7},
      labels: [],
      dispatchable: true
    }

    assert [%Issue{id: "issue-7", agent_profile: :codex}] = ReviewJob.expand(regular_issue)

    claude_issue = %{regular_issue | labels: ["claude"]}
    assert [%Issue{id: "issue-7", agent_profile: :claude}] = ReviewJob.expand(claude_issue)

    conflicting_issue = %{regular_issue | labels: ["claude", "codex"]}
    assert ReviewJob.expand(conflicting_issue) == []

    assert ReviewJob.expand(%Issue{}) == []
    assert ReviewJob.for_profile(regular_issue, :unknown) == nil
    assert ReviewJob.routable?(regular_issue)
    assert ReviewJob.label_present?(regular_issue)
    assert ReviewJob.marker(regular_issue) == nil

    pr_job = %Issue{
      id: "42@codex-review",
      agent_profile: :codex,
      native_ref: %{"pull_request" => true, "job_id" => "42@codex-review"}
    }

    assert ReviewJob.marker(pr_job) == "<!-- symphony-review:42@codex-review -->"
    assert ReviewJob.parse_review_id("42@codex-review") == {:ok, "42", :codex}
    assert ReviewJob.parse_review_id("42@unsupported") == :error

    assert ReviewJob.select_requested([regular_issue], ["not-a-number@claude-review"]) == []
    assert ReviewJob.select_requested([regular_issue], ["missing-issue"]) == []
    assert ReviewJob.select_requested([regular_issue], ["99@claude-review"]) == []

    assert [%Issue{id: "issue-7", agent_profile: :codex}] =
             ReviewJob.select_requested([regular_issue], ["issue-7"])
  end

  test "client pages state reads, filters requested states, and drops malformed records" do
    first_page =
      Enum.map(1..97, &raw_issue/1) ++
        [
          Map.put(raw_issue(98), "pull_request", %{"url" => "https://api.github.test/pulls/98"}),
          Map.put(raw_issue(99), "state", "closed"),
          Map.put(raw_issue(100), "title", "")
        ]

    request_fun = fn "GET", "/repos/octo/repo/issues", params, nil, settings ->
      send(self(), {:github_page, params, settings})

      body =
        case params["page"] do
          1 -> first_page
          2 -> [raw_issue(101)]
        end

      {:ok, %{status: 200, body: body}}
    end

    log =
      capture_log(fn ->
        assert {:ok, issues} =
                 GitHubClient.fetch_issues_by_states_for_test(
                   [" OPEN "],
                   tracker_settings(),
                   request_fun
                 )

        assert length(issues) == 99
        assert hd(issues).id == "1"
        assert List.last(issues).id == "101"
        refute Enum.any?(issues, &(&1.id == "99"))
        assert Enum.find(issues, &(&1.id == "98")).dispatchable == false
      end)

    assert log =~ "Dropping malformed GitHub issue records count=1"

    assert_receive {:github_page,
                    %{
                      "state" => "open",
                      "per_page" => 100,
                      "page" => 1,
                      "sort" => "created",
                      "direction" => "asc"
                    }, %{repo: "octo/repo"}}

    assert_receive {:github_page, %{"page" => 2}, %{repo: "octo/repo"}}

    assert {:ok, []} =
             GitHubClient.fetch_issues_by_states_for_test(
               ["In Progress"],
               tracker_settings(),
               fn _method, _path, _params, _body, _settings ->
                 flunk("unsupported GitHub states should not make an HTTP request")
               end
             )
  end

  test "client refreshes numeric IDs in order, omits 404s, and rejects malformed refreshes" do
    request_fun = fn "GET", path, %{}, nil, _settings ->
      send(self(), {:github_id_path, path})

      case path do
        "/repos/octo/repo/issues/2" -> {:ok, %{status: 200, body: raw_issue(2)}}
        "/repos/octo/repo/issues/1" -> {:ok, %{status: 200, body: raw_issue(1)}}
        "/repos/octo/repo/issues/404" -> {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
      end
    end

    assert {:ok, issues} =
             GitHubClient.fetch_issues_by_ids_for_test(
               ["2", "1", "404", "2"],
               tracker_settings(),
               request_fun
             )

    assert Enum.map(issues, & &1.id) == ["2", "1"]
    assert_receive {:github_id_path, "/repos/octo/repo/issues/2"}
    assert_receive {:github_id_path, "/repos/octo/repo/issues/1"}
    assert_receive {:github_id_path, "/repos/octo/repo/issues/404"}
    refute_receive {:github_id_path, "/repos/octo/repo/issues/2"}

    assert {:error, :invalid_github_issue_id} =
             GitHubClient.fetch_issues_by_ids_for_test(
               ["not-a-number"],
               tracker_settings(),
               request_fun
             )

    assert {:error, :github_unknown_payload} =
             GitHubClient.fetch_issues_by_ids_for_test(
               ["3"],
               tracker_settings(),
               fn _method, _path, _params, _body, _settings ->
                 {:ok, %{status: 200, body: Map.put(raw_issue(3), "title", "")}}
               end
             )
  end

  test "github_api preserves REST status and body while rejecting unsafe arguments" do
    test_pid = self()
    tracker_settings = tracker_settings()

    response =
      GitHubAgentTool.execute(
        "github_api",
        %{
          "method" => "post",
          "path" => " /repos/octo/repo/issues/42/comments ",
          "params" => %{"per_page" => 10},
          "body" => %{"body" => "hello"}
        },
        tracker_settings: tracker_settings,
        github_client: fn method, path, params, body, opts ->
          send(test_pid, {:github_tool_called, method, path, params, body, opts})
          {:ok, %{status: 201, body: %{"id" => 9}}}
        end
      )

    assert_received {:github_tool_called, "POST", "/repos/octo/repo/issues/42/comments", %{"per_page" => 10}, %{"body" => "hello"}, [tracker_settings: ^tracker_settings]}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"status" => 201, "body" => %{"id" => 9}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]

    failure =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/repos/octo/repo/issues/404"},
        github_client: fn _method, _path, _params, _body, _opts ->
          {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
        end
      )

    assert failure["success"] == false

    assert Jason.decode!(failure["output"]) == %{
             "status" => 404,
             "body" => %{"message" => "Not Found"}
           }

    Enum.each(
      [
        %{"method" => "GET", "path" => "https://api.github.com/user"},
        %{"method" => "GET", "path" => "/user", "params" => false},
        %{"path" => "/user"}
      ],
      fn arguments ->
        invalid =
          GitHubAgentTool.execute(
            "github_api",
            arguments,
            github_client: fn _method, _path, _params, _body, _opts ->
              flunk("invalid github_api arguments should not call the client")
            end
          )

        assert invalid["success"] == false
      end
    )
  end

  test "github_api reports unsupported tools, malformed calls, and client failures" do
    unsupported = GitHubAgentTool.execute("not_github_api", %{}, [])
    assert unsupported["success"] == false
    assert Jason.decode!(unsupported["output"])["error"]["supportedTools"] == ["github_api"]

    Enum.each(
      [
        "not-an-object",
        %{"method" => "GET", "path" => 123}
      ],
      fn arguments ->
        invalid =
          GitHubAgentTool.execute(
            "github_api",
            arguments,
            github_client: fn _method, _path, _params, _body, _opts ->
              flunk("malformed github_api arguments should not call the client")
            end
          )

        assert invalid["success"] == false
      end
    )

    malformed_response =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/user"},
        github_client: fn _method, _path, _params, _body, _opts ->
          {:ok, %{status: "not-an-integer", body: %{}}}
        end
      )

    assert malformed_response["success"] == false

    Enum.each(
      [
        :missing_github_token,
        {:github_api_request, :timeout},
        :unexpected_failure
      ],
      fn reason ->
        failure =
          GitHubAgentTool.execute(
            "github_api",
            %{"method" => "GET", "path" => "/user"},
            github_client: fn _method, _path, _params, _body, _opts ->
              {:error, reason}
            end
          )

        assert failure["success"] == false
        assert %{"error" => %{"message" => message}} = Jason.decode!(failure["output"])
        assert is_binary(message)
      end
    )

    non_json_body =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/user"},
        github_client: fn _method, _path, _params, _body, _opts ->
          {:ok, %{status: 200, body: self()}}
        end
      )

    assert non_json_body["success"]
    assert non_json_body["output"] =~ "#PID"

    unknown_payload =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/user"},
        github_client: fn _method, _path, _params, _body, _opts -> :unexpected end
      )

    refute unknown_payload["success"]
    assert Jason.decode!(unknown_payload["output"])["error"]["reason"] == ":github_unknown_payload"
  end

  test "github review jobs reject out-of-scope API paths and malformed review entries" do
    issue = review_issue_for_test()

    out_of_scope =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/repos/octo/other/pulls/99"},
        issue: issue,
        github_client: fn _method, _path, _params, _body, _opts ->
          flunk("out-of-scope review requests must not reach GitHub")
        end
      )

    refute out_of_scope["success"]
    assert Jason.decode!(out_of_scope["output"])["error"]["message"] =~ "outside the current pull request"

    invalid_review =
      delete_review_label(
        issue,
        fn _issue, _action -> :ok end,
        fn method, path, _params, _body, _opts ->
          case {method, path} do
            {"GET", "/repos/octo/repo/pulls/42"} ->
              {:ok, %{status: 200, body: %{"head" => %{"sha" => "expected-sha"}}}}

            {"GET", "/repos/octo/repo/pulls/42/reviews"} ->
              {:ok, %{status: 200, body: [nil]}}
          end
        end
      )

    refute invalid_review["success"]
    assert Jason.decode!(invalid_review["output"])["error"]["message"] =~ "cannot be removed"
  end

  test "github_api allows read-only PR review endpoints within the current job" do
    issue = review_issue_for_test()

    for path <- [
          "/repos/octo/repo/pulls/42/files",
          "/repos/octo/repo/pulls/42/commits",
          "/repos/octo/repo/pulls/42/reviews",
          "/repos/octo/repo/pulls/42/comments",
          "/repos/octo/repo/issues/42",
          "/repos/octo/repo/issues/42/comments"
        ] do
      response =
        GitHubAgentTool.execute(
          "github_api",
          %{"method" => "GET", "path" => path},
          issue: issue,
          github_client: fn "GET", ^path, _params, _body, _opts ->
            {:ok, %{status: 200, body: []}}
          end
        )

      assert response["success"]
    end
  end

  test "github_api handles profile-scoped label transitions and callback failures" do
    issue = review_issue_for_test()

    authorize_error =
      delete_review_label(
        issue,
        fn _issue, :authorize -> {:error, :orchestrator_unavailable} end,
        &valid_review_delete_response/5
      )

    refute authorize_error["success"]
    assert authorize_error["output"] =~ "could not authorize this review-label transition"

    unexpected_authorization =
      delete_review_label(issue, fn _issue, :authorize -> :unexpected end, &valid_review_delete_response/5)

    refute unexpected_authorization["success"]

    completion_callback_error =
      delete_review_label(
        issue,
        fn _issue, action -> if action == :authorize, do: :ok, else: {:error, :orchestrator_stopped} end,
        &valid_review_delete_response/5
      )

    assert completion_callback_error["success"]

    completion_callback_unexpected =
      delete_review_label(
        issue,
        fn _issue, action -> if action == :authorize, do: :ok, else: :unexpected end,
        &valid_review_delete_response/5
      )

    assert completion_callback_unexpected["success"]
  end

  test "github_api deletes only the Codex label for a Codex review job" do
    issue = %{
      review_issue_for_test()
      | agent_profile: :codex,
        native_ref: %{
          "repo" => "octo/repo",
          "number" => 42,
          "pull_request" => true,
          "head_sha" => "expected-sha",
          "job_id" => "42@codex-review",
          "profile" => "codex"
        }
    }

    response =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "DELETE", "path" => "/repos/octo/repo/issues/42/labels/codex-review"},
        issue: issue,
        on_review_label_removal: fn _issue, _action -> :ok end,
        github_client: fn method, path, _params, _body, _opts ->
          case {method, path} do
            {"GET", "/repos/octo/repo/pulls/42"} ->
              {:ok, %{status: 200, body: %{"head" => %{"sha" => "expected-sha"}}}}

            {"GET", "/repos/octo/repo/pulls/42/reviews"} ->
              {:ok,
               %{
                 status: 200,
                 body: [
                   %{
                     "commit_id" => "expected-sha",
                     "state" => "COMMENTED",
                     "body" => "Review <!-- symphony-review:42@codex-review -->"
                   }
                 ]
               }}

            {"DELETE", "/repos/octo/repo/issues/42/labels/codex-review"} ->
              {:ok, %{status: 200, body: %{}}}
          end
        end
      )

    assert response["success"]
  end

  test "github_api treats a non-review issue label deletion as an ordinary REST request" do
    response =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "DELETE", "path" => "/repos/octo/repo/issues/9/labels/symphony"},
        issue: %Issue{native_ref: %{"repo" => "octo/repo", "number" => 9}},
        github_client: fn "DELETE", _path, _params, _body, _opts ->
          {:ok, %{status: 200, body: %{}}}
        end
      )

    assert response["success"]
  end

  test "github_api refuses to publish a review against a stale PR head" do
    issue = %Issue{
      native_ref: %{
        "repo" => "octo/repo",
        "number" => 42,
        "pull_request" => true,
        "head_sha" => "expected-sha",
        "job_id" => "42@codex-review",
        "profile" => "codex"
      }
    }

    response =
      GitHubAgentTool.execute(
        "github_api",
        %{
          "method" => "POST",
          "path" => "/repos/octo/repo/pulls/42/reviews",
          "body" => %{
            "commit_id" => "expected-sha",
            "body" => "Finding <!-- symphony-review:42@codex-review -->"
          }
        },
        issue: issue,
        github_client: fn method, path, _params, _body, _opts ->
          send(self(), {:github_request, method, path})

          case {method, path} do
            {"GET", "/repos/octo/repo/pulls/42"} ->
              {:ok, %{status: 200, body: %{"head" => %{"sha" => "new-sha"}}}}

            _ ->
              flunk("a stale review must not be posted")
          end
        end
      )

    refute response["success"]
    assert response["output"] =~ "current pull request head"
    assert_receive {:github_request, "GET", "/repos/octo/repo/pulls/42"}
    refute_receive {:github_request, "POST", _path}
  end

  test "github_api removes only its own label after a marked current-head review exists" do
    issue = %Issue{
      agent_profile: :claude,
      native_ref: %{
        "repo" => "octo/repo",
        "number" => 42,
        "pull_request" => true,
        "head_sha" => "expected-sha",
        "job_id" => "42@claude-review",
        "profile" => "claude"
      }
    }

    response =
      GitHubAgentTool.execute(
        "github_api",
        %{
          "method" => "DELETE",
          "path" => "/repos/octo/repo/issues/42/labels/claude-review"
        },
        issue: issue,
        on_review_label_removal: fn _issue, action ->
          send(self(), {:label_transition, action})
          :ok
        end,
        github_client: fn method, path, _params, _body, _opts ->
          send(self(), {:github_request, method, path})

          case {method, path} do
            {"GET", "/repos/octo/repo/pulls/42"} ->
              {:ok, %{status: 200, body: %{"head" => %{"sha" => "expected-sha"}}}}

            {"GET", "/repos/octo/repo/pulls/42/reviews"} ->
              {:ok,
               %{
                 status: 200,
                 body: [
                   %{
                     "commit_id" => "expected-sha",
                     "state" => "COMMENTED",
                     "body" => "Review <!-- symphony-review:42@claude-review -->"
                   }
                 ]
               }}

            {"DELETE", "/repos/octo/repo/issues/42/labels/claude-review"} ->
              {:ok, %{status: 200, body: %{}}}

            _ ->
              flunk("unexpected GitHub API request")
          end
        end
      )

    assert response["success"]
    assert_receive {:github_request, "GET", "/repos/octo/repo/pulls/42"}
    assert_receive {:github_request, "GET", "/repos/octo/repo/pulls/42/reviews"}
    assert_receive {:github_request, "DELETE", "/repos/octo/repo/issues/42/labels/claude-review"}
    assert_receive {:label_transition, :authorize}
    assert_receive {:label_transition, :complete}
  end

  test "github_api requires an orchestrator transition callback before removing a review label" do
    issue = review_issue_for_test()

    response =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "DELETE", "path" => "/repos/octo/repo/issues/42/labels/claude-review"},
        issue: issue,
        github_client: fn method, path, _params, _body, _opts ->
          send(self(), {:github_request, method, path})

          case {method, path} do
            {"GET", "/repos/octo/repo/pulls/42"} ->
              {:ok, %{status: 200, body: %{"head" => %{"sha" => "expected-sha"}}}}

            {"GET", "/repos/octo/repo/pulls/42/reviews"} ->
              {:ok, %{status: 200, body: [commented_review_for_test()]}}

            _ ->
              flunk("label removal must be blocked without an orchestrator transition")
          end
        end
      )

    refute response["success"]
    assert response["output"] =~ "could not authorize this review-label transition"
    assert_receive {:github_request, "GET", "/repos/octo/repo/pulls/42"}
    assert_receive {:github_request, "GET", "/repos/octo/repo/pulls/42/reviews"}
    refute_receive {:github_request, "DELETE", _path}
  end

  test "github_api refuses to remove a label when the job has no pinned head" do
    issue = %{review_issue_for_test() | native_ref: Map.delete(review_issue_for_test().native_ref, "head_sha")}

    response =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "DELETE", "path" => "/repos/octo/repo/issues/42/labels/claude-review"},
        issue: issue,
        github_client: fn _method, _path, _params, _body, _opts ->
          flunk("a review without a pinned head cannot remove its label")
        end
      )

    refute response["success"]
    assert response["output"] =~ "pinned PR head"
  end

  test "github_api restores the review label when the head changes during label removal" do
    issue = review_issue_for_test()
    head_reads = Agent.start_link(fn -> 0 end) |> elem(1)

    response =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "DELETE", "path" => "/repos/octo/repo/issues/42/labels/claude-review"},
        issue: issue,
        on_review_label_removal: fn _issue, action ->
          send(self(), {:label_transition, action})
          :ok
        end,
        github_client: fn method, path, _params, _body, _opts ->
          send(self(), {:github_request, method, path})

          case {method, path} do
            {"GET", "/repos/octo/repo/pulls/42"} ->
              sha = Agent.get_and_update(head_reads, fn reads -> {if(reads == 0, do: "expected-sha", else: "changed-sha"), reads + 1} end)
              {:ok, %{status: 200, body: %{"head" => %{"sha" => sha}}}}

            {"GET", "/repos/octo/repo/pulls/42/reviews"} ->
              {:ok, %{status: 200, body: [commented_review_for_test()]}}

            {"DELETE", "/repos/octo/repo/issues/42/labels/claude-review"} ->
              {:ok, %{status: 200, body: %{}}}

            {"POST", "/repos/octo/repo/issues/42/labels"} ->
              {:ok, %{status: 200, body: [%{"name" => "claude-review"}]}}
          end
        end
      )

    refute response["success"]
    assert response["output"] =~ "current pull request head"
    assert_receive {:github_request, "GET", "/repos/octo/repo/pulls/42"}
    assert_receive {:github_request, "GET", "/repos/octo/repo/pulls/42/reviews"}
    assert_receive {:github_request, "DELETE", "/repos/octo/repo/issues/42/labels/claude-review"}
    assert_receive {:github_request, "GET", "/repos/octo/repo/pulls/42"}
    assert_receive {:github_request, "POST", "/repos/octo/repo/issues/42/labels"}
    assert_receive {:label_transition, :authorize}
    assert_receive {:label_transition, :revoke}
  end

  test "github_api reports failure when it cannot restore a stale review label" do
    issue = review_issue_for_test()
    head_reads = Agent.start_link(fn -> 0 end) |> elem(1)

    response =
      delete_review_label(
        issue,
        fn _issue, _action -> :ok end,
        fn method, path, _params, _body, _opts ->
          case {method, path} do
            {"GET", "/repos/octo/repo/pulls/42"} ->
              sha = Agent.get_and_update(head_reads, fn reads -> {if(reads == 0, do: "expected-sha", else: "changed-sha"), reads + 1} end)
              {:ok, %{status: 200, body: %{"head" => %{"sha" => sha}}}}

            {"GET", "/repos/octo/repo/pulls/42/reviews"} ->
              {:ok, %{status: 200, body: [commented_review_for_test()]}}

            {"DELETE", "/repos/octo/repo/issues/42/labels/claude-review"} ->
              {:ok, %{status: 200, body: %{}}}

            {"POST", "/repos/octo/repo/issues/42/labels"} ->
              {:error, :forbidden}
          end
        end
      )

    refute response["success"]
    assert response["output"] =~ "current pull request head"
  end

  test "github_api does not remove the review label for a pending review" do
    issue = review_issue_for_test()

    response =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "DELETE", "path" => "/repos/octo/repo/issues/42/labels/claude-review"},
        issue: issue,
        github_client: fn method, path, _params, _body, _opts ->
          send(self(), {:github_request, method, path})

          case {method, path} do
            {"GET", "/repos/octo/repo/pulls/42"} ->
              {:ok, %{status: 200, body: %{"head" => %{"sha" => "expected-sha"}}}}

            {"GET", "/repos/octo/repo/pulls/42/reviews"} ->
              {:ok,
               %{
                 status: 200,
                 body: [Map.put(commented_review_for_test(), "state", "PENDING")]
               }}

            _ ->
              flunk("pending reviews must not remove the label")
          end
        end
      )

    refute response["success"]
    assert response["output"] =~ "review is published"
    assert_receive {:github_request, "GET", "/repos/octo/repo/pulls/42"}
    assert_receive {:github_request, "GET", "/repos/octo/repo/pulls/42/reviews"}
    refute_receive {:github_request, "DELETE", _path}
  end

  test "completion verification requires the review, pinned head, and removed job label" do
    issue = %Issue{
      agent_profile: :claude,
      native_ref: %{
        "repo" => "octo/repo",
        "number" => 42,
        "pull_request" => true,
        "head_sha" => "expected-sha",
        "job_id" => "42@claude-review",
        "profile" => "claude"
      }
    }

    request_fun = fn method, path, _params, body, _settings ->
      send(self(), {:github_request, method, path})

      case {method, path} do
        {"GET", "/repos/octo/repo/issues/42"} ->
          {:ok, %{status: 200, body: %{"labels" => [%{"name" => "symphony"}]}}}

        {"GET", "/repos/octo/repo/pulls/42"} ->
          {:ok, %{status: 200, body: %{"head" => %{"sha" => "expected-sha"}}}}

        {"POST", "/repos/octo/repo/issues/42/labels"} ->
          assert body == %{"labels" => ["claude-review"]}
          {:ok, %{status: 200, body: [%{"name" => "claude-review"}]}}

        {"GET", "/repos/octo/repo/pulls/42/reviews"} ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "commit_id" => "expected-sha",
                 "state" => "COMMENTED",
                 "body" => "No findings <!-- symphony-review:42@claude-review -->"
               }
             ]
           }}
      end
    end

    assert :ok = GitHubClient.verify_review_completion_for_test(issue, tracker_settings(), request_fun)
    assert_receive {:github_request, "GET", "/repos/octo/repo/issues/42"}
    assert_receive {:github_request, "GET", "/repos/octo/repo/pulls/42"}
    assert_receive {:github_request, "GET", "/repos/octo/repo/pulls/42/reviews"}

    stale_request_fun = fn method, path, params, body, settings ->
      case {method, path} do
        {"GET", "/repos/octo/repo/pulls/42"} ->
          send(self(), {:github_request, method, path})
          {:ok, %{status: 200, body: %{"head" => %{"sha" => "changed-sha"}}}}

        _ ->
          request_fun.(method, path, params, body, settings)
      end
    end

    assert {:error, :github_review_not_completed} =
             GitHubClient.verify_review_completion_for_test(issue, tracker_settings(), stale_request_fun)

    assert_receive {:github_request, "GET", "/repos/octo/repo/issues/42"}
    assert_receive {:github_request, "GET", "/repos/octo/repo/pulls/42"}
    assert_receive {:github_request, "GET", "/repos/octo/repo/pulls/42/reviews"}
    assert_receive {:github_request, "POST", "/repos/octo/repo/issues/42/labels"}
  end

  test "completion verification reports a failed label restore when GitHub returns 404" do
    issue = review_issue_for_test()

    request_fun = fn method, path, _params, _body, _settings ->
      case {method, path} do
        {"GET", "/repos/octo/repo/issues/42"} ->
          {:ok, %{status: 200, body: %{"labels" => [%{"name" => "symphony"}]}}}

        {"GET", "/repos/octo/repo/pulls/42"} ->
          {:ok, %{status: 200, body: %{"head" => %{"sha" => "changed-sha"}}}}

        {"GET", "/repos/octo/repo/pulls/42/reviews"} ->
          {:ok, %{status: 200, body: []}}

        {"POST", "/repos/octo/repo/issues/42/labels"} ->
          {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
      end
    end

    assert {:error, {:github_review_label_restore_failed, {:github_api_status, 404}}} =
             GitHubClient.verify_review_completion_for_test(issue, tracker_settings(), request_fun)
  end

  test "tracker binds GitHub tools and token env names from provider config" do
    token_env = "SYMPHONY_GITHUB_TOKEN_#{System.unique_integer([:positive])}"
    previous_token = System.get_env(token_env)
    System.put_env(token_env, "test-token")

    on_exit(fn -> restore_env(token_env, previous_token) end)

    write_github_workflow!(Workflow.workflow_file_path(), "$#{token_env}")

    binding = Tracker.bind_agent_tools()

    assert binding.adapter == GitHubAdapter

    assert binding.secret_environment_names == [
             "GITHUB_TOKEN",
             "GH_TOKEN",
             "GITHUB_ENTERPRISE_TOKEN",
             "GH_ENTERPRISE_TOKEN",
             token_env
           ]

    assert [%{"name" => "github_api"}] = binding.tool_specs
    assert :ok = Config.validate!()
  end

  defp tracker_settings(provider_overrides \\ %{}) do
    %{
      kind: "github",
      provider:
        Map.merge(
          %{
            "repo" => "octo/repo",
            "token" => "test-token"
          },
          provider_overrides
        ),
      active_states: ["open"],
      terminal_states: ["closed"]
    }
  end

  defp review_issue_for_test do
    %Issue{
      agent_profile: :claude,
      native_ref: %{
        "repo" => "octo/repo",
        "number" => 42,
        "pull_request" => true,
        "head_sha" => "expected-sha",
        "job_id" => "42@claude-review",
        "profile" => "claude"
      }
    }
  end

  defp delete_review_label(issue, callback, github_client) do
    label = "#{issue.agent_profile}-review"

    GitHubAgentTool.execute(
      "github_api",
      %{"method" => "DELETE", "path" => "/repos/octo/repo/issues/42/labels/#{label}"},
      issue: issue,
      on_review_label_removal: callback,
      github_client: github_client
    )
  end

  defp valid_review_delete_response("GET", "/repos/octo/repo/pulls/42", _params, _body, _opts) do
    {:ok, %{status: 200, body: %{"head" => %{"sha" => "expected-sha"}}}}
  end

  defp valid_review_delete_response("GET", "/repos/octo/repo/pulls/42/reviews", _params, _body, _opts) do
    {:ok, %{status: 200, body: [commented_review_for_test()]}}
  end

  defp valid_review_delete_response("DELETE", path, _params, _body, _opts) do
    if path in [
         "/repos/octo/repo/issues/42/labels/claude-review",
         "/repos/octo/repo/issues/42/labels/codex-review"
       ] do
      {:ok, %{status: 200, body: %{}}}
    else
      flunk("unexpected GitHub label deletion path: #{path}")
    end
  end

  defp valid_review_delete_response(method, path, _params, _body, _opts) do
    flunk("unexpected GitHub request #{method} #{path}")
  end

  defp commented_review_for_test do
    %{
      "commit_id" => "expected-sha",
      "state" => "COMMENTED",
      "body" => "Review <!-- symphony-review:42@claude-review -->"
    }
  end

  defp raw_issue(number) do
    %{
      "number" => number,
      "id" => 1_000 + number,
      "node_id" => "I_#{number}",
      "title" => "Issue #{number}",
      "body" => "Body #{number}",
      "state" => "open",
      "html_url" => "https://github.test/octo/repo/issues/#{number}",
      "assignee" => %{"login" => "octocat"},
      "labels" => [%{"name" => " Bug "}, %{"name" => "bug"}, %{"name" => "Platform"}],
      "created_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-02T00:00:00Z"
    }
  end

  defp write_github_workflow!(path, token) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: github
        provider:
          repo: "octo/repo"
          token: #{Jason.encode!(token)}
        active_states: ["open"]
        terminal_states: ["closed"]
      ---

      You are working on {{ issue.identifier }}.
      """
    )

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    end
  end
end
