defmodule SymphonyElixir.GitHub.ReviewJob do
  @moduledoc "Expands labeled pull requests into independent agent review jobs."

  alias SymphonyElixir.Tracker.Issue

  @claude_label "claude-review"
  @codex_label "codex-review"
  @claude_issue_label "claude"
  @codex_issue_label "codex"

  @spec expand(Issue.t()) :: [Issue.t()]
  def expand(%Issue{native_ref: %{"pull_request" => true, "head_sha" => sha}} = issue)
      when is_binary(sha) and sha != "" do
    labels = MapSet.new(issue.labels, &normalize_label/1)

    [
      {@claude_label, :claude},
      {@codex_label, :codex}
    ]
    |> Enum.flat_map(fn {label, profile} ->
      if MapSet.member?(labels, label), do: List.wrap(for_profile(issue, profile)), else: []
    end)
  end

  def expand(%Issue{native_ref: %{"pull_request" => true}}), do: []

  def expand(%Issue{native_ref: native_ref} = issue) when is_map(native_ref) do
    case implementation_profile(issue) do
      {:ok, profile} -> [%{issue | agent_profile: profile}]
      :conflict -> []
    end
  end

  def expand(%Issue{}), do: []

  @spec for_profile(Issue.t(), :codex | :claude) :: Issue.t() | nil
  def for_profile(%Issue{native_ref: %{"pull_request" => true, "head_sha" => sha}} = issue, profile)
      when profile in [:codex, :claude] and is_binary(sha) and sha != "" do
    review_issue(issue, profile)
  end

  def for_profile(_issue, _profile), do: nil

  @spec routable?(Issue.t()) :: boolean()
  def routable?(%Issue{} = issue) do
    case label(issue) do
      nil -> implementation_profile(issue) == {:ok, issue.agent_profile}
      required_label -> Enum.any?(issue.labels, &(normalize_label(&1) == required_label))
    end
  end

  @spec label_present?(Issue.t()) :: boolean()
  def label_present?(%Issue{} = issue) do
    case label(issue) do
      nil -> implementation_profile(issue) == {:ok, issue.agent_profile}
      required_label -> Enum.any?(issue.labels, &(normalize_label(&1) == required_label))
    end
  end

  @spec implementation_label_present?(Issue.t()) :: boolean()
  def implementation_label_present?(%Issue{} = issue) do
    labels = MapSet.new(issue.labels, &normalize_label/1)
    MapSet.member?(labels, @claude_issue_label) or MapSet.member?(labels, @codex_issue_label)
  end

  @spec review_id(String.t(), :codex | :claude) :: String.t()
  def review_id(number, profile) when is_binary(number) and profile in [:codex, :claude] do
    "#{number}@#{profile}-review"
  end

  @spec parse_review_id(String.t()) :: {:ok, String.t(), :codex | :claude} | :error
  def parse_review_id(id) when is_binary(id) do
    case String.split(id, "@", parts: 2) do
      [number, "codex-review"] when number != "" -> {:ok, number, :codex}
      [number, "claude-review"] when number != "" -> {:ok, number, :claude}
      _ -> :error
    end
  end

  @spec label(Issue.t()) :: String.t() | nil
  def label(%Issue{agent_profile: profile, native_ref: %{"pull_request" => true}})
      when profile in [:codex, :claude],
      do: "#{profile}-review"

  def label(_issue), do: nil

  @spec marker(Issue.t()) :: String.t() | nil
  def marker(%Issue{native_ref: %{"pull_request" => true, "job_id" => job_id}})
      when is_binary(job_id),
      do: "<!-- symphony-review:#{job_id} -->"

  def marker(_issue), do: nil

  @spec select_requested([Issue.t()], [String.t()]) :: [Issue.t()]
  def select_requested(issues, requested_ids) when is_list(issues) and is_list(requested_ids) do
    requested_ids
    |> Enum.flat_map(&requested_jobs(issues, &1))
    |> Enum.uniq_by(& &1.id)
  end

  defp requested_jobs(issues, id) do
    case parse_review_id(id) do
      {:ok, number, profile} ->
        requested_review_job(issues, parse_number(number), profile)

      :error ->
        Enum.flat_map(issues, fn
          %Issue{id: ^id} = issue -> expand(issue)
          _ -> []
        end)
    end
  end

  defp requested_review_job(issues, number, profile) when is_integer(number) do
    Enum.flat_map(issues, fn
      %Issue{native_ref: %{"number" => ^number}} = issue -> List.wrap(for_profile(issue, profile))
      _ -> []
    end)
  end

  defp requested_review_job(_issues, _number, _profile), do: []

  defp implementation_profile(issue) do
    labels = MapSet.new(issue.labels, &normalize_label/1)
    has_claude? = MapSet.member?(labels, @claude_issue_label)
    has_codex? = MapSet.member?(labels, @codex_issue_label)

    case {has_claude?, has_codex?} do
      {true, true} -> :conflict
      {true, false} -> {:ok, :claude}
      _ -> {:ok, :codex}
    end
  end

  defp review_issue(issue, profile) do
    number = to_string(issue.native_ref["number"])
    id = review_id(number, profile)

    native_ref =
      Map.merge(issue.native_ref, %{
        "job_id" => id,
        "profile" => Atom.to_string(profile)
      })

    %{
      issue
      | id: id,
        identifier: "#{issue.identifier}-#{profile}-review",
        native_ref: native_ref,
        agent_profile: profile,
        dispatchable: true
    }
  end

  defp normalize_label(label) when is_binary(label), do: label |> String.trim() |> String.downcase()

  defp parse_number(number) do
    case Integer.parse(number) do
      {value, ""} -> value
      _ -> nil
    end
  end
end
