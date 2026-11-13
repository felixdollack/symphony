defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from normalized tracker work item data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Tracker.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    if review_job?(issue) do
      build_review_prompt(issue)
    else
      template =
        Workflow.current()
        |> prompt_template!()
        |> parse_template!()

      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue |> Map.from_struct() |> to_solid_map()
        },
        @render_opts
      )
      |> IO.iodata_to_binary()
    end
  end

  defp review_job?(%{agent_profile: profile, native_ref: %{"pull_request" => true}})
       when profile in [:codex, :claude],
       do: true

  defp review_job?(_issue), do: false

  defp build_review_prompt(issue) do
    agent_name = if issue.agent_profile == :claude, do: "Claude", else: "Codex"

    """
    You are #{agent_name}, conducting an independent code review of GitHub pull request #{issue.identifier}.

    Repository: #{issue.native_ref["repo"]}
    Pull request: #{issue.url}
    Title: #{issue.title}
    Pinned head: #{issue.native_ref["head_sha"]}
    Review marker: `<!-- symphony-review:#{issue.native_ref["job_id"]} -->`

    Review the pull request diff for concrete correctness, security, and regression bugs. Do not make source changes.
    Before reviewing, fetch `refs/pull/#{issue.native_ref["number"]}/head` and check out the pinned head commit above. Base every finding on that exact commit.
    Report only actionable findings, with file and line references and a concise explanation of impact.
    Publish findings through the `github_api` tool as a pull request review. Include `commit_id` equal to the pinned head and include the exact review marker in the review body. If there are inline findings, send them in the review's `comments` array.
    The host verifies that the current PR head still matches the pinned commit and rejects stale reviews.
    Remove only the `#{issue.agent_profile}-review` label through `github_api` after the host confirms that this job's marked review exists on the pinned head.
    If there are no findings, publish a concise no-findings review containing the marker before removing the label.
    """
    |> String.trim()
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
