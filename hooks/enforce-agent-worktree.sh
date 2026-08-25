#!/usr/bin/env bash
# PreToolUse guard. Two rules, enforced only for git-tracked paths:
#   1. Mutating work must run inside a subagent (hook input carries agent_id).
#   2. It must target a linked git worktree, never the main checkout.
# Opt out of a repo by listing its toplevel in ~/.claude/hooks/no-isolation-repos
# (one absolute path per line, # for comments), or by a .claude/no-isolation file
# in the repo. Kill the guard for a whole session with CLAUDE_ENFORCE_OFF=1.
set -uo pipefail

in=$(cat)
q() { printf '%s' "$in" | jq -r "$1 // \"\"" 2>/dev/null; }

tool=$(q '.tool_name')
agent=$(q '.agent_id')
cwd=$(q '.cwd')
path=$(q '.tool_input.file_path // .tool_input.notebook_path')
cmd=$(q '.tool_input.command')

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

[ "${CLAUDE_ENFORCE_OFF:-}" = "1" ] && exit 0

# Bash: only guard commands that can actually mutate the tree.
# Redirects: drop /dev/* targets and fd duplications (2>&1) before looking for >.
# The git subcommand list ends with ([^-[:alnum:]_]|$), not \b: a trailing \b sits
# happily before the hyphen in read-only commands like `git merge-base`, so those
# were denied as if they were `git merge`.
if [ "$tool" = "Bash" ]; then
  bare=$(printf '%s' "$cmd" \
    | sed -E 's@[0-9]*>>?[[:space:]]*/dev/(null|stderr|stdout|fd/[0-9]+)@@g' \
    | sed -E 's@[0-9]*>>?&[0-9-]@@g')
  printf '%s' "$bare" | grep -Eq \
    '>[[:space:]]*[^&[:space:]]|\b(sed[[:space:]]+-i|perl[[:space:]]+-i|tee|mv|rm|cp|patch|touch|mkdir|rmdir|ln|chmod|npm|yarn|pnpm|bun|make|cargo|gofmt|go[[:space:]]+(build|generate|mod)|dd)\b|\bgit[[:space:]]+(commit|apply|am|checkout|switch|merge|rebase|reset|revert|clean|stash|add|rm|mv|restore)([^-[:alnum:]_]|$)' \
    || exit 0
fi

dir=$cwd
[ -n "$path" ] && dir=$(dirname "$path")
[ -d "$dir" ] || dir=$cwd

git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
[ -n "$top" ] && [ -f "$top/.claude/no-isolation" ] && exit 0

# Global opt-out list, kept outside any repo so it needs no in-repo marker file.
exempt=~/.claude/hooks/no-isolation-repos
if [ -n "$top" ] && [ -f "$exempt" ]; then
  common_root=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  main_top=${common_root%/.git}
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    line=${line%/}
    eval "line=$line" 2>/dev/null
    [ "$line" = "$top" ] || [ "$line" = "$main_top" ] && exit 0
  done < "$exempt"
fi

if [ -z "$agent" ]; then
  deny "この作業はメインスレッドから直接実行できません。Agent ツールでサブエージェントに委譲してください（例: Agent(subagent_type:\"general-purpose\", isolation:\"worktree\")）。ファイルの読み取り・調査はメインスレッドで可。どうしても直接やる必要があるなら、ユーザーに CLAUDE_ENFORCE_OFF=1 での起動を依頼してください。"
fi

gd=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)
common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)
case "$common" in /*) ;; *) common=$(cd "$dir" && cd "$common" 2>/dev/null && pwd);; esac
[ -n "$gd" ] && [ "$gd" = "$common" ] && \
  deny "メインチェックアウト ($top) は変更できません。git worktree 内で作業してください。Agent は isolation:\"worktree\" で起動する、またはセッション側で EnterWorktree / claude --worktree を使ってください。"

exit 0
