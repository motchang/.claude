#!/bin/bash
# Report the PRs a Claude Code session is working on to its herdr pane, so the
# agent list in herdr's sidebar can show them as $pr (see the dotfiles repo's
# .config/herdr/config.toml, [ui.sidebar.agents]).
#
# Runs from SessionStart and Stop. The lookup goes to the background at once:
# `gh` is a network call and the transcript can be tens of MB, and a Stop hook
# that waits on either holds up every turn.
#
# Which PRs count:
#   - ones the session made: a `gh pr create` whose result printed a PR URL,
#     in the main transcript or a subagent's (subagents open PRs too);
#   - ones the user pasted: a PR URL in a prompt the user typed;
#   - the open PR for the branch checked out in the cwd, unless that branch is
#     the default one.
# A PR URL that only turns up in a tool result - `gh pr list`, a search, a page
# read in passing - does not count. Counting those put PRs the session merely
# looked at in front of the one it was about.
#
# Shown newest first, two at most, then how many more: "#3323 #3319 +2".
# Nothing found clears the token, so a stale number does not outlive its PR.

[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v herdr >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
pane=$HERDR_PANE_ID

# One transcript to "<timestamp>\t<kind>\t<value>" lines:
#   C <tool_use_id>  a Bash call that ran `gh pr create`
#   R <tool_use_id>\t<url>  the PR URL in a tool result
#   U <url>  a PR URL in a prompt the user typed (main transcript only - a
#            subagent's first "user" message is the prompt Claude wrote for it)
# grep first: jq over every line of a large transcript is the slow part, and
# only lines holding a PR URL or a `gh pr create` can matter.
scan() {
  grep -hE 'pull/[0-9]|gh pr create' "$1" 2>/dev/null | jq -r --argjson main "$2" '
    def urls: [scan("github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+")];
    (.timestamp // "") as $ts
    | if .type == "assistant" then
        .message.content[]?
        | select(.type == "tool_use" and .name == "Bash"
                 and ((.input.command // "") | test("gh pr create")))
        | "\($ts)\tC\t\(.id)"
      elif .type == "user" then
        if (.message.content | type) == "string" then
          if $main then
            .message.content
            | select((startswith("<") or startswith("Another Claude session")) | not)
            | urls[] | "\($ts)\tU\t\(.)"
          else empty end
        else
          .message.content[]?
          | select(.type == "tool_result")
          | ((.content | if type == "array" then map(.text // "") | join("\n")
                         else (. // "") end) | urls | last) as $u
          | select($u != null)
          | "\($ts)\tR\t\(.tool_use_id)\t\($u)"
        end
      else empty end' 2>/dev/null
}

(
  {
    if [ -r "$transcript" ]; then
      scan "$transcript" true
      for f in "${transcript%.jsonl}"/subagents/*.jsonl; do
        [ -r "$f" ] && scan "$f" false
      done
    fi

    branch=$(git -C "${cwd:-.}" symbolic-ref --quiet --short HEAD 2>/dev/null)
    case $branch in
      ''|main|master|develop) ;;
      *)
        if command -v gh >/dev/null 2>&1; then
          n=$(cd "${cwd:-.}" && gh pr view --json number,state \
            -q 'select(.state == "OPEN") | .number' 2>/dev/null)
          # The checked-out branch is what the session is on right now: newest.
          [ -n "$n" ] && printf '9999\tU\tpull/%s\n' "$n"
        fi
        ;;
    esac
  } | sort -t "$(printf '\t')" -k1,1 -s | awk -F '\t' '
    $2 == "C" { made[$3] = 1; next }
    $2 == "R" { if ($3 in made) url = $4; else next }
    $2 == "U" { url = $3 }
    {
      n = url; sub(/.*\/pull\//, "", n)
      if (n in seen) { order[seen[n]] = "" }      # keep only the latest mention
      seen[n] = ++k; order[k] = n
    }
    END {
      out = ""; shown = 0; total = 0
      for (i = k; i >= 1; i--) if (order[i] != "") {
        total++
        if (shown < 2) { out = out (out == "" ? "" : " ") "#" order[i]; shown++ }
      }
      if (total > 2) out = out " +" (total - 2)
      print out
    }' > "${TMPDIR:-/tmp}/herdr-report-pr.$$"

  pr=$(cat "${TMPDIR:-/tmp}/herdr-report-pr.$$" 2>/dev/null)
  command rm -f "${TMPDIR:-/tmp}/herdr-report-pr.$$"

  if [ -n "$pr" ]; then
    herdr pane report-metadata "$pane" --source claude-pr --token "pr=${pr}"
  else
    herdr pane report-metadata "$pane" --source claude-pr --clear-token pr
  fi
) </dev/null >/dev/null 2>&1 &

exit 0
