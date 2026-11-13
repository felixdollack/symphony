defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub REST client for repository issue polling.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.ReviewJob
  alias SymphonyElixir.Tracker.Issue

  @default_api_url "https://api.github.com"
  @api_version "2022-11-28"
  @page_size 100
  @user_agent "symphony"

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    with {:ok, _settings} <- settings(tracker_settings), do: :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings) do
    provider = provider_settings(tracker_settings)

    [
      "GITHUB_TOKEN",
      "GH_TOKEN",
      "GITHUB_ENTERPRISE_TOKEN",
      "GH_ENTERPRISE_TOKEN" | env_reference_names([provider["token"]])
    ]
    |> Enum.uniq()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    tracker_settings = Config.settings!().tracker

    with {:ok, issues} <- fetch_issues_by_states(state_names, tracker_settings, &perform_request/5),
         {:ok, github_settings} <- settings(tracker_settings) do
      issues
      |> Enum.map(fn issue -> hydrate_review_head(issue, github_settings, &perform_request/5, false) end)
      |> Enum.flat_map(&ReviewJob.expand/1)
      |> then(&{:ok, &1})
    end
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) when is_list(issue_ids) do
    base_ids = issue_ids |> Enum.map(&base_issue_id/1) |> Enum.uniq()
    tracker_settings = Config.settings!().tracker

    with {:ok, issues} <- fetch_issues_by_ids(base_ids, tracker_settings, &perform_request/5),
         {:ok, github_settings} <- settings(tracker_settings) do
      issues
      |> Enum.map(fn issue ->
        hydrate_review_head(issue, github_settings, &perform_request/5, true)
      end)
      |> then(&{:ok, ReviewJob.select_requested(&1, issue_ids)})
    end
  end

  @spec verify_review_completion(Issue.t()) :: :ok | {:error, term()}
  def verify_review_completion(%Issue{} = issue) do
    verify_review_completion(issue, Config.settings!().tracker, &perform_request/5)
  end

  @doc false
  @spec verify_review_completion_for_test(Issue.t(), map(), function()) :: :ok | {:error, term()}
  def verify_review_completion_for_test(%Issue{} = issue, tracker_settings, request_fun)
      when is_map(tracker_settings) and is_function(request_fun, 5) do
    verify_review_completion(issue, tracker_settings, request_fun)
  end

  @spec request(String.t(), String.t(), map(), term(), keyword()) ::
          {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def request(method, path, params, body, opts \\ [])
      when is_binary(method) and is_binary(path) and is_map(params) and is_list(opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, github_settings} <- settings(tracker_settings) do
      request_fun.(method, path, params, body, github_settings)
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t()) :: Issue.t() | nil
  def normalize_issue_for_test(issue, repo) when is_map(issue) and is_binary(repo) do
    normalize_issue(issue, repo)
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(state_names, tracker_settings, request_fun)
      when is_list(state_names) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_states(state_names, tracker_settings, request_fun)
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(issue_ids, tracker_settings, request_fun)
      when is_list(issue_ids) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_ids(issue_ids, tracker_settings, request_fun)
  end

  defp fetch_issues_by_states(state_names, tracker_settings, request_fun) do
    normalized_states = state_names |> Enum.map(&normalize_state/1) |> MapSet.new()

    case github_state_query(normalized_states) do
      nil ->
        {:ok, []}

      state_query ->
        with {:ok, github_settings} <- settings(tracker_settings) do
          do_fetch_pages(github_settings, state_query, normalized_states, 1, request_fun, [])
        end
    end
  end

  defp fetch_issues_by_ids(issue_ids, tracker_settings, request_fun) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, github_settings} <- settings(tracker_settings) do
          fetch_issue_ids(ids, github_settings, request_fun, [])
        end
    end
  end

  defp do_fetch_pages(settings, state_query, requested_states, page, request_fun, acc) do
    params = %{
      "state" => state_query,
      "per_page" => @page_size,
      "page" => page,
      "sort" => "created",
      "direction" => "asc"
    }

    with {:ok, payload} <-
           request_with_settings(
             "GET",
             repository_issues_path(settings),
             params,
             nil,
             settings,
             request_fun,
             false
           ),
         true <- is_list(payload) or {:error, :github_unknown_payload} do
      issues = normalize_state_page(payload, settings.repo, requested_states)
      updated_acc = [issues | acc]

      if length(payload) < @page_size do
        {:ok, updated_acc |> Enum.reverse() |> List.flatten()}
      else
        do_fetch_pages(settings, state_query, requested_states, page + 1, request_fun, updated_acc)
      end
    end
  end

  defp fetch_issue_ids([], _settings, _request_fun, acc), do: {:ok, Enum.reverse(acc)}

  defp fetch_issue_ids([id | rest], settings, request_fun, acc) do
    with {:ok, issue_number} <- parse_issue_number(id),
         {:ok, payload} <-
           request_with_settings(
             "GET",
             repository_issue_path(settings, issue_number),
             %{},
             nil,
             settings,
             request_fun,
             true
           ) do
      continue_issue_id_fetch(payload, rest, settings, request_fun, acc)
    end
  end

  defp continue_issue_id_fetch(:not_found, rest, settings, request_fun, acc) do
    fetch_issue_ids(rest, settings, request_fun, acc)
  end

  defp continue_issue_id_fetch(%{} = raw_issue, rest, settings, request_fun, acc) do
    case normalize_issue(raw_issue, settings.repo) do
      %Issue{} = issue -> fetch_issue_ids(rest, settings, request_fun, [issue | acc])
      nil -> {:error, :github_unknown_payload}
    end
  end

  defp continue_issue_id_fetch(_payload, _rest, _settings, _request_fun, _acc) do
    {:error, :github_unknown_payload}
  end

  defp normalize_state_page(payload, repo, requested_states) do
    issues = Enum.map(payload, &normalize_issue(&1, repo))
    malformed_count = Enum.count(issues, &is_nil/1)

    if malformed_count > 0 do
      Logger.warning("Dropping malformed GitHub issue records count=#{malformed_count}")
    end

    issues
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&MapSet.member?(requested_states, normalize_state(&1.state)))
  end

  defp normalize_issue(issue, repo) when is_map(issue) and is_binary(repo) do
    issue_number = issue["number"]
    state = issue["state"]

    if is_integer(issue_number) and issue_number > 0 and
         Enum.all?([issue["title"], state], &present_string?/1) do
      %Issue{
        id: Integer.to_string(issue_number),
        native_ref: native_ref(issue, repo),
        identifier: "GH-#{issue_number}",
        title: issue["title"],
        description: issue["body"],
        state: state,
        url: issue["html_url"],
        assignee_id: get_in(issue, ["assignee", "login"]),
        labels: extract_labels(issue),
        blocked_by: [],
        dispatchable: not Map.has_key?(issue, "pull_request"),
        created_at: parse_datetime(issue["created_at"]),
        updated_at: parse_datetime(issue["updated_at"])
      }
    end
  end

  defp normalize_issue(_issue, _repo), do: nil

  defp native_ref(issue, repo) do
    %{
      "id" => issue["id"],
      "node_id" => issue["node_id"],
      "number" => issue["number"],
      "repo" => repo,
      "pull_request" => Map.has_key?(issue, "pull_request")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> case do
      empty when map_size(empty) == 0 -> nil
      ref -> ref
    end
  end

  defp base_issue_id(id) when is_binary(id) do
    case ReviewJob.parse_review_id(id) do
      {:ok, number, _profile} -> number
      :error -> id
    end
  end

  defp hydrate_review_head(%Issue{native_ref: %{"pull_request" => true} = native_ref} = issue, settings, request_fun, force?) do
    labels = MapSet.new(issue.labels, &String.downcase/1)

    if force? or MapSet.member?(labels, "claude-review") or MapSet.member?(labels, "codex-review") do
      number = native_ref["number"]

      case request_with_settings(
             "GET",
             repository_pull_request_path(settings, number),
             %{},
             nil,
             settings,
             request_fun,
             true
           ) do
        {:ok, %{"head" => %{"sha" => sha}}} when is_binary(sha) ->
          %{issue | native_ref: Map.put(native_ref, "head_sha", sha)}

        result ->
          Logger.warning("Skipping labeled GitHub pull request without a pinned head issue_id=#{issue.id} issue_identifier=#{issue.identifier} result=#{inspect(result)}")

          issue
      end
    else
      issue
    end
  end

  defp hydrate_review_head(issue, _settings, _request_fun, _force?), do: issue

  defp verify_review_completion(issue, tracker_settings, request_fun) do
    ref = issue.native_ref || %{}
    number = ref["number"]
    expected_sha = ref["head_sha"]
    marker = "<!-- symphony-review:#{ref["job_id"]} -->"
    own_label = "#{issue.agent_profile}-review"

    with {:ok, github_settings} <- settings(tracker_settings),
         {:ok, current_issue} <-
           request_with_settings(
             "GET",
             repository_issue_path(github_settings, number),
             %{},
             nil,
             github_settings,
             request_fun,
             false
           ),
         {:ok, current_pr} <-
           request_with_settings(
             "GET",
             repository_pull_request_path(github_settings, number),
             %{},
             nil,
             github_settings,
             request_fun,
             false
           ),
         {:ok, reviews} <-
           request_with_settings(
             "GET",
             "#{repository_pull_request_path(github_settings, number)}/reviews",
             %{},
             nil,
             github_settings,
             request_fun,
             false
           ),
         true <- is_map(current_issue) and is_map(current_pr) and is_list(reviews),
         :ok <- restore_review_label_for_stale_head(current_issue, current_pr, github_settings, issue, request_fun),
         true <- current_pr["head"]["sha"] == expected_sha,
         true <- not Enum.any?(extract_labels(current_issue), &(String.downcase(&1) == own_label)),
         true <- Enum.any?(reviews, &matching_review?(&1, expected_sha, marker)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_review_not_completed}
    end
  end

  defp restore_review_label_for_stale_head(current_issue, current_pr, github_settings, issue, request_fun) do
    native_ref = issue.native_ref || %{}
    expected_sha = native_ref["head_sha"]
    current_sha = get_in(current_pr, ["head", "sha"])
    own_label = "#{issue.agent_profile}-review"

    label_present? = Enum.any?(extract_labels(current_issue), &(String.downcase(&1) == own_label))

    if is_binary(expected_sha) and is_binary(current_sha) and current_sha != expected_sha and not label_present? do
      case request_with_settings(
             "POST",
             repository_issue_path(github_settings, native_ref["number"]) <> "/labels",
             %{},
             %{"labels" => [own_label]},
             github_settings,
             request_fun,
             false
           ) do
        {:ok, _payload} ->
          :ok

        {:error, reason} ->
          {:error, {:github_review_label_restore_failed, reason}}
      end
    else
      :ok
    end
  end

  defp matching_review?(%{"commit_id" => sha, "body" => body, "state" => state}, expected_sha, marker) do
    sha == expected_sha and state in ["COMMENTED", "APPROVED", "CHANGES_REQUESTED"] and
      is_binary(body) and String.contains?(body, marker)
  end

  defp matching_review?(_review, _expected_sha, _marker), do: false

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_labels(_issue), do: []

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp request_with_settings(method, path, params, body, settings, request_fun, allow_not_found) do
    case request_fun.(method, path, params, body, settings) do
      {:ok, %{status: status, body: payload}} when status in 200..299 ->
        {:ok, payload}

      {:ok, %{status: 404}} when allow_not_found ->
        {:ok, :not_found}

      {:ok, %{status: status}} when is_integer(status) ->
        Logger.error("GitHub API request failed status=#{status} method=#{method} path=#{path}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :github_unknown_payload}
    end
  end

  defp perform_request(method, path, params, body, settings) do
    with {:ok, request_method} <- request_method(method) do
      request_opts = [
        method: request_method,
        url: settings.api_url <> path,
        headers: github_headers(settings.token),
        params: params,
        connect_options: [timeout: 30_000]
      ]

      request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :json, body)

      case Req.request(request_opts) do
        {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
        {:error, reason} -> {:error, {:github_api_request, reason}}
      end
    end
  end

  defp settings(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)
    api_url = provider["api_url"] || @default_api_url
    repo = resolve_setting(provider["repo"], System.get_env("GITHUB_REPO"))
    token = resolve_setting(provider["token"], System.get_env("GITHUB_TOKEN"))

    cond do
      not valid_api_url?(api_url) -> {:error, :invalid_github_api_url}
      not present_string?(repo) -> {:error, :missing_github_repo}
      not valid_repo?(repo) -> {:error, :invalid_github_repo}
      not present_string?(token) -> {:error, :missing_github_token}
      true -> {:ok, %{api_url: String.trim_trailing(api_url, "/"), repo: repo, token: token}}
    end
  end

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(_tracker_settings), do: %{}

  defp resolve_setting(nil, fallback), do: normalize_string(fallback)

  defp resolve_setting("$" <> env_name, fallback) do
    if valid_env_name?(env_name) do
      normalize_string(System.get_env(env_name) || fallback)
    else
      nil
    end
  end

  defp resolve_setting(value, _fallback), do: normalize_string(value)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp env_reference_names(values) do
    Enum.flat_map(values, fn
      "$" <> env_name when is_binary(env_name) -> if valid_env_name?(env_name), do: [env_name], else: []
      _ -> []
    end)
  end

  defp valid_env_name?(name), do: String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp valid_api_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) -> true
      _ -> false
    end
  end

  defp valid_api_url?(_value), do: false
  defp valid_repo?(repo) when is_binary(repo), do: String.match?(repo, ~r/^[^\s\/]+\/[^\s\/]+$/)
  defp valid_repo?(_repo), do: false

  defp repository_issues_path(settings), do: "/repos/#{encoded_repo(settings.repo)}/issues"

  defp repository_issue_path(settings, issue_number),
    do: "#{repository_issues_path(settings)}/#{issue_number}"

  defp repository_pull_request_path(settings, pr_number),
    do: "/repos/#{encoded_repo(settings.repo)}/pulls/#{pr_number}"

  defp encoded_repo(repo) do
    repo
    |> String.split("/", parts: 2)
    |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
  end

  defp github_headers(token) do
    [
      {"Accept", "application/vnd.github+json"},
      {"Authorization", "Bearer #{token}"},
      {"X-GitHub-Api-Version", @api_version},
      {"User-Agent", @user_agent}
    ]
  end

  defp github_state_query(states) do
    has_open? = MapSet.member?(states, "open")
    has_closed? = MapSet.member?(states, "closed")

    cond do
      has_open? and has_closed? -> "all"
      has_open? -> "open"
      has_closed? -> "closed"
      true -> nil
    end
  end

  defp parse_issue_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_github_issue_id}
    end
  end

  defp parse_issue_number(_value), do: {:error, :invalid_github_issue_id}

  defp request_method("GET"), do: {:ok, :get}
  defp request_method("POST"), do: {:ok, :post}
  defp request_method("PATCH"), do: {:ok, :patch}
  defp request_method("PUT"), do: {:ok, :put}
  defp request_method("DELETE"), do: {:ok, :delete}
  defp request_method(_method), do: {:error, :invalid_github_method}

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
