defmodule SymphonyElixir.GitHub.AgentTool do
  @moduledoc """
  Provider-native GitHub REST tool exposed to Codex app-server turns.
  """

  require Logger
  alias SymphonyElixir.GitHub.Client

  @github_api_tool "github_api"
  @allowed_methods ["GET", "POST", "PATCH", "PUT", "DELETE"]
  @github_api_description """
  Execute a GitHub REST API request using Symphony's configured auth.
  """
  @github_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "enum" => @allowed_methods,
        "description" => "GitHub REST method."
      },
      "path" => %{
        "type" => "string",
        "description" => "GitHub REST path such as /repos/owner/repo/issues/1/comments."
      },
      "params" => %{
        "type" => ["object", "null"],
        "description" => "Optional query parameters.",
        "additionalProperties" => true
      },
      "body" => %{
        "description" => "Optional JSON request body."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) do
    case tool do
      @github_api_tool -> execute_github_api(arguments, opts)
      other -> unsupported_tool_response(other)
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @github_api_tool,
        "description" => @github_api_description,
        "inputSchema" => @github_api_input_schema
      }
    ]
  end

  defp execute_github_api(arguments, opts) do
    github_client = Keyword.get(opts, :github_client, &Client.request/5)
    client_opts = Keyword.take(opts, [:tracker_settings])

    with {:ok, method, path, params, body} <- normalize_arguments(arguments),
         :ok <- validate_review_job_operation(method, path, body, opts, github_client, client_opts),
         :ok <- notify_review_label_removal(method, path, opts) do
      github_client.(method, path, params, body, client_opts)
      |> handle_github_api_response(method, path, opts, github_client, client_opts)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp handle_github_api_response({:ok, %{status: status, body: response_body}}, method, path, opts, github_client, client_opts)
       when is_integer(status) and status in 200..299 do
    handle_successful_github_response(status, response_body, method, path, opts, github_client, client_opts)
  end

  defp handle_github_api_response({:ok, %{status: status, body: response_body}}, method, path, opts, _github_client, _client_opts)
       when is_integer(status) do
    finish_review_label_removal(method, path, opts, :revoke)
    rest_response(status, response_body)
  end

  defp handle_github_api_response({:error, reason}, method, path, opts, _github_client, _client_opts) do
    finish_review_label_removal(method, path, opts, :revoke)
    failure_response(tool_error_payload(reason))
  end

  defp handle_github_api_response(_result, method, path, opts, _github_client, _client_opts) do
    finish_review_label_removal(method, path, opts, :revoke)
    failure_response(tool_error_payload(:github_unknown_payload))
  end

  defp handle_successful_github_response(status, response_body, method, path, opts, github_client, client_opts) do
    case verify_head_after_label_removal(method, path, opts, github_client, client_opts) do
      :ok ->
        finish_review_label_removal(method, path, opts, :complete)
        rest_response(status, response_body)

      {:error, reason} ->
        finish_review_label_removal(method, path, opts, :revoke)
        failure_response(tool_error_payload(reason))
    end
  end

  defp notify_review_label_removal("DELETE", path, opts) do
    case review_label_transition_issue(path, opts) do
      nil -> :ok
      issue -> authorize_review_label_transition(issue, opts)
    end
  end

  defp notify_review_label_removal(_method, _path, _opts), do: :ok

  defp finish_review_label_removal("DELETE", path, opts, action) when action in [:complete, :revoke] do
    case review_label_transition_issue(path, opts) do
      nil -> :ok
      issue -> finish_label_transition(issue, action, opts)
    end
  end

  defp finish_review_label_removal(_method, _path, _opts, _action), do: :ok

  defp review_label_transition_issue(path, opts) do
    case Keyword.get(opts, :issue) do
      %{native_ref: %{"pull_request" => true} = native_ref} = issue ->
        expected_path = "/repos/#{native_ref["repo"]}/issues/#{native_ref["number"]}/labels/#{review_label(native_ref)}"
        if path == expected_path, do: issue

      _issue ->
        nil
    end
  end

  defp authorize_review_label_transition(issue, opts) do
    case Keyword.get(opts, :on_review_label_removal) do
      callback when is_function(callback, 2) ->
        case callback.(issue, :authorize) do
          :ok -> :ok
          {:error, reason} -> {:error, {:review_label_transition_failed, reason}}
          other -> {:error, {:review_label_transition_failed, other}}
        end

      _ ->
        {:error, {:review_label_transition_failed, :transition_callback_unavailable}}
    end
  end

  defp finish_label_transition(issue, action, opts) do
    transition = if action == :complete, do: :complete, else: :revoke
    callback = Keyword.fetch!(opts, :on_review_label_removal)

    case callback.(issue, transition) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to update review label transition state: #{inspect(reason)}")
      other -> Logger.warning("Unexpected review label transition response: #{inspect(other)}")
    end
  end

  defp validate_review_job_operation(method, path, body, opts, github_client, client_opts) do
    case Keyword.get(opts, :issue) do
      %{agent_profile: profile, native_ref: %{"pull_request" => true} = native_ref}
      when profile in [:claude, :codex] ->
        validate_scoped_review_request(method, path, body, native_ref, github_client, client_opts)

      _issue ->
        :ok
    end
  end

  defp validate_scoped_review_request(method, path, body, native_ref, github_client, client_opts) do
    repo = native_ref["repo"]
    number = native_ref["number"]
    number_text = to_string(number)
    prefix = "/repos/#{repo}"
    pr_path = "#{prefix}/pulls/#{number_text}"
    issue_path = "#{prefix}/issues/#{number_text}"

    cond do
      method == "GET" and
          path in [
            pr_path,
            "#{pr_path}/files",
            "#{pr_path}/commits",
            "#{pr_path}/reviews",
            "#{pr_path}/comments",
            issue_path,
            "#{issue_path}/comments"
          ] ->
        :ok

      method == "POST" and path == "#{pr_path}/reviews" ->
        validate_review_publication(body, native_ref, github_client, client_opts)

      method == "DELETE" and String.starts_with?(path, "#{issue_path}/labels/") ->
        label = String.replace_prefix(path, "#{issue_path}/labels/", "")
        validate_label_removal(label, native_ref, github_client, client_opts)

      true ->
        {:error, :review_job_request_out_of_scope}
    end
  end

  defp validate_review_publication(body, native_ref, github_client, client_opts) do
    with {:ok, expected_sha} <- pinned_head_sha(native_ref),
         true <- is_map(body) and body["commit_id"] == expected_sha,
         true <- is_binary(body["body"]) and String.contains?(body["body"], review_marker(native_ref)),
         :ok <- verify_current_head(native_ref, expected_sha, github_client, client_opts) do
      :ok
    else
      _ -> {:error, :stale_pull_request_head}
    end
  end

  defp validate_label_removal(label, native_ref, github_client, client_opts) do
    own_label = if get_in(native_ref, ["profile"]) == "claude", do: "claude-review", else: "codex-review"

    with true <- label == own_label,
         {:ok, expected_sha} <- pinned_head_sha(native_ref),
         :ok <- verify_current_head(native_ref, expected_sha, github_client, client_opts),
         {:ok, %{status: status, body: reviews}} <-
           github_client.("GET", "/repos/#{native_ref["repo"]}/pulls/#{native_ref["number"]}/reviews", %{}, nil, client_opts),
         true <- status in 200..299 and is_list(reviews),
         true <- Enum.any?(reviews, &review_matches_job?(&1, expected_sha, native_ref)) do
      :ok
    else
      _ -> {:error, :review_not_published_for_current_head}
    end
  end

  defp pinned_head_sha(native_ref) do
    case native_ref["head_sha"] do
      sha when is_binary(sha) and sha != "" -> {:ok, sha}
      _ -> {:error, :missing_pinned_head_sha}
    end
  end

  defp verify_current_head(native_ref, expected_sha, github_client, client_opts) do
    path = "/repos/#{native_ref["repo"]}/pulls/#{native_ref["number"]}"

    case github_client.("GET", path, %{}, nil, client_opts) do
      {:ok, %{status: status, body: %{"head" => %{"sha" => ^expected_sha}}}} when status in 200..299 ->
        :ok

      _ ->
        {:error, :stale_pull_request_head}
    end
  end

  defp review_matches_job?(%{"commit_id" => sha, "body" => body, "state" => state}, expected_sha, native_ref) do
    sha == expected_sha and state in ["COMMENTED", "APPROVED", "CHANGES_REQUESTED"] and
      is_binary(body) and String.contains?(body, review_marker(native_ref))
  end

  defp review_matches_job?(_review, _expected_sha, _native_ref), do: false

  defp verify_head_after_label_removal("DELETE", path, opts, github_client, client_opts) do
    case review_label_transition_issue(path, opts) do
      %{native_ref: native_ref} -> validate_deleted_label_head(native_ref, github_client, client_opts)
      nil -> :ok
    end
  end

  defp verify_head_after_label_removal(_method, _path, _opts, _github_client, _client_opts), do: :ok

  defp validate_deleted_label_head(native_ref, github_client, client_opts) do
    with {:ok, expected_sha} <- pinned_head_sha(native_ref),
         :ok <- verify_current_head(native_ref, expected_sha, github_client, client_opts) do
      :ok
    else
      _error ->
        restore_review_label(native_ref, github_client, client_opts)
        {:error, :stale_pull_request_head}
    end
  end

  defp restore_review_label(native_ref, github_client, client_opts) do
    label = review_label(native_ref)
    path = "/repos/#{native_ref["repo"]}/issues/#{native_ref["number"]}/labels"

    case github_client.("POST", path, %{}, %{"labels" => [label]}, client_opts) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      result ->
        Logger.error("Failed to restore review label after PR head changed repo=#{native_ref["repo"]} number=#{native_ref["number"]} label=#{label} result=#{inspect(result)}")

        :error
    end
  end

  defp review_label(%{"profile" => "claude"}), do: "claude-review"
  defp review_label(_native_ref), do: "codex-review"

  defp review_marker(native_ref), do: "<!-- symphony-review:#{native_ref["job_id"]} -->"

  defp normalize_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_method(Map.get(arguments, "method")),
         {:ok, path} <- normalize_path(Map.get(arguments, "path")),
         {:ok, params} <- normalize_params(Map.get(arguments, "params")) do
      {:ok, method, path, params, Map.get(arguments, "body")}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_method(method) when is_binary(method) do
    normalized = method |> String.trim() |> String.upcase()
    if normalized in @allowed_methods, do: {:ok, normalized}, else: {:error, :invalid_method}
  end

  defp normalize_method(_method), do: {:error, :invalid_method}

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    if String.starts_with?(trimmed, "/") and not String.contains?(trimmed, ["://", "\n", "\r", <<0>>]) do
      {:ok, trimmed}
    else
      {:error, :invalid_path}
    end
  end

  defp normalize_path(_path), do: {:error, :invalid_path}

  defp normalize_params(nil), do: {:ok, %{}}
  defp normalize_params(params) when is_map(params), do: {:ok, params}
  defp normalize_params(_params), do: {:error, :invalid_params}

  defp rest_response(status, body) do
    dynamic_tool_response(status in 200..299, encode_payload(%{"status" => status, "body" => body}))
  end

  defp failure_response(payload), do: dynamic_tool_response(false, encode_payload(payload))

  defp dynamic_tool_response(success, output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp encode_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, output} -> output
      {:error, _reason} -> inspect(payload)
    end
  end

  defp unsupported_tool_response(tool) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => supported_tool_names()
      }
    })
  end

  defp tool_error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "`github_api` expects an object with `method` and `path`."}}
  end

  defp tool_error_payload(:invalid_method) do
    %{"error" => %{"message" => "`github_api.method` must be GET, POST, PATCH, PUT, or DELETE."}}
  end

  defp tool_error_payload(:invalid_path) do
    %{"error" => %{"message" => "`github_api.path` must be a relative GitHub REST path."}}
  end

  defp tool_error_payload(:invalid_params) do
    %{"error" => %{"message" => "`github_api.params` must be a JSON object when provided."}}
  end

  defp tool_error_payload(:stale_pull_request_head) do
    %{
      "error" => %{
        "message" => "The review was rejected because its commit does not match the current pull request head. Refresh the PR and review the new commit."
      }
    }
  end

  defp tool_error_payload(:review_job_request_out_of_scope) do
    %{"error" => %{"message" => "This GitHub request is outside the current pull request review job."}}
  end

  defp tool_error_payload(:review_not_published_for_current_head) do
    %{"error" => %{"message" => "The review label cannot be removed until this job's review is published on the current pinned PR head."}}
  end

  defp tool_error_payload({:review_label_transition_failed, reason}) do
    %{"error" => %{"message" => "Symphony could not authorize this review-label transition.", "reason" => inspect(reason)}}
  end

  defp tool_error_payload(:missing_github_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing GitHub auth. Set `tracker.provider.token` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
      }
    }
  end

  defp tool_error_payload({:github_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitHub API request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{"error" => %{"message" => "GitHub API tool execution failed.", "reason" => inspect(reason)}}
  end

  defp supported_tool_names, do: Enum.map(tool_specs(), & &1["name"])
end
