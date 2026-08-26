#!/usr/bin/env bash
# PreToolUse guard. Two rules, enforced only for changes to a git working tree:
#   1. Mutating work must run inside a subagent (hook input carries agent_id).
#   2. It must target a linked git worktree, never the main checkout.
# Reading, searching, building and testing stay on the main thread. The Bash
# filter looks at the word in *command position* and at the paths that word is
# handed, so `grep -rn npm .`, `cargo check` and `echo x > /tmp/scratch` are not
# repository changes, while `rm src/a`, `npm install` and `git commit` are.
# Opt out of a repo by listing its toplevel in ~/.claude/hooks/no-isolation-repos
# (one absolute path per line, # for comments), or by a .claude/no-isolation file
# in the repo. Kill the guard for a whole session with CLAUDE_ENFORCE_OFF=1.
set -uo pipefail
set -f   # no globbing: arguments are inspected as written, never expanded

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

# ---------------------------------------------------------------- path helpers

# Absolute, symlink-resolved path for one argument. The file usually does not
# exist yet (a redirect target), so only its parent directory is resolved.
abspath() {
  local p=$1 d b
  p=${p#[\"\']}; p=${p%[\"\']}
  case $p in
    '~') p=$HOME;;
    '~/'*) p=$HOME/${p#'~/'};;
  esac
  case $p in /*) ;; *) p=$pdir/$p;; esac
  b=${p##*/}; d=${p%/*}; [ -n "$d" ] || d=/
  d=$(cd "$d" 2>/dev/null && pwd -P) || d=${p%/*}
  printf '%s/%s' "${d%/}" "$b"
}

inside_repo() {
  local p; p=$(abspath "$1")
  case $p in "$top"|"$top"/*) return 0;; esac
  return 1
}

# ------------------------------------------------------------- command parsing

# One shell command per line, so the word in command position can be found.
# Splitting inside a quoted string is harmless: the fragments do not start with
# a mutating verb, and a real verb is still seen in its own segment.
segments() { printf '%s\n' "$1" | tr ';|&(){}`' '\n\n\n\n\n\n\n\n'; }

# Words of one segment with redirects and their targets removed, so a target is
# never mistaken for an argument.
seg_words() {
  local s
  s=$(printf '%s' "$1" | sed -E 's/[0-9]*(>>?|<<?)[|]?[[:space:]]*[^[:space:]]*//g')
  read -ra WORDS <<<"$s"
}

# CMDW: the command being run, CMDIDX: where it sits in WORDS. Assignments and
# wrappers (sudo, env, time, ...) are stepped over.
parse_seg() {
  local i=0 w
  seg_words "$1"
  CMDW=""; CMDIDX=0
  for w in "${WORDS[@]}"; do
    case $w in
      *=*|sudo|env|command|nohup|time|exec|builtin|then|do|else|'!'|-*) i=$((i+1));;
      *) CMDW=${w##*/}; CMDW=${CMDW#[\"\']}; CMDIDX=$i; return;;
    esac
  done
}

# First real argument after a given word, stepping over flags and the handful of
# flags that take a separate value.
sub_word() {
  local seg=$1 after=$2 w hit=0 skip=0
  seg_words "$seg"
  for w in "${WORDS[@]}"; do
    if [ "$hit" = 0 ]; then [ "${w##*/}" = "$after" ] && hit=1; continue; fi
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case $w in
      -C|-c|-f|-j|-e|-p|-P|--file|--git-dir|--work-tree|--manifest-path|--exec-path) skip=1;;
      -*) ;;
      *) printf '%s' "$w"; return;;
    esac
  done
}

# ------------------------------------------------------------- mutation tests

# Redirect targets that are real files inside the repository.
writes_into_repo() {
  local t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case $t in /dev/*) continue;; esac
    inside_repo "$t" && return 0
  done < <(printf '%s' "$1" \
    | sed -E 's/[0-9]*>>?&[0-9-]+//g' \
    | grep -oE '[0-9]*>>?[|]?[[:space:]]*[^[:space:];&|)]+' \
    | sed -E 's/^[0-9]*>>?[|]?[[:space:]]*//')
  return 1
}

# Does any path-shaped argument land in the repository? A command handed no path
# at all (`make`, `git add -A`) works on the current directory, which is already
# known to be inside the repository.
args_touch_repo() {
  local w seen=0
  seg_words "$1"
  for w in "${WORDS[@]:$((CMDIDX+1))}"; do
    case $w in -*) continue;; esac
    seen=1
    inside_repo "$w" && return 0
  done
  [ "$seen" = 0 ]
}

has_flag() { printf '%s' "$1" | grep -Eq -- "(^|[[:space:]])$2([[:space:]=]|$)"; }

seg_mutates() {
  local seg=$1
  # find -exec and xargs hide a second command inside one segment.
  if printf '%s' "$seg" | grep -Eq -- '(-execdir|-exec|xargs)[[:space:]]+(sudo[[:space:]]+)?[A-Za-z0-9_./-]*/?(mv|rm|cp|ln|chmod|chown|touch|mkdir|sed|perl|tee|dd|truncate|shred|git)([[:space:]]|$)'; then
    args_touch_repo "$seg" && return 0
  fi
  case $CMDW in
    mv|rm|cp|rsync|touch|mkdir|rmdir|ln|unlink|chmod|chown|tee|dd|patch|truncate|shred|install)
      args_touch_repo "$seg";;
    sed|perl|ruby)
      { has_flag "$seg" '-[a-zA-Z]*i' || has_flag "$seg" '--in-place'; } && args_touch_repo "$seg";;
    gofmt)
      has_flag "$seg" '-[a-zA-Z]*w' && args_touch_repo "$seg";;
    git)
      case $(sub_word "$seg" git) in
        commit|apply|am|checkout|switch|merge|rebase|reset|revert|clean|add|rm|mv|restore|cherry-pick|pull|submodule|filter-branch) return 0;;
        stash) case $(sub_word "$seg" stash) in list|show|'') return 1;; *) return 0;; esac;;
        *) return 1;;
      esac;;
    npm|pnpm|yarn|bun)
      case $(sub_word "$seg" "$CMDW") in
        install|i|ci|add|remove|rm|uninstall|un|update|up|upgrade|link|unlink|publish|init|dedupe|prune|import) return 0;;
        *) return 1;;
      esac;;
    cargo)
      case $(sub_word "$seg" cargo) in
        add|remove|rm|update|fix|fmt|clean|init|new|vendor|publish|install|uninstall|generate-lockfile) return 0;;
        *) return 1;;
      esac;;
    go)
      case $(sub_word "$seg" go) in
        generate|mod|get|work|fmt|fix|install|clean) return 0;;
        *) return 1;;
      esac;;
    make|gmake)
      # -n and -q only print or answer; anything else may write.
      has_flag "$seg" '-[a-zA-Z]*[nq]' && return 1
      return 0;;
    *) return 1;;
  esac
}

mutates_repo() {
  local seg
  while IFS= read -r seg; do
    [ -n "${seg//[[:space:]]/}" ] || continue
    writes_into_repo "$seg" && return 0
    parse_seg "$seg"
    [ -n "$CMDW" ] || continue
    seg_mutates "$seg" && return 0
  done < <(segments "$1")
  return 1
}

# ---------------------------------------------------------------------- guard

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

if [ "$tool" = "Bash" ]; then
  # $top is physical, cwd may reach it through a symlink; resolve so a relative
  # argument compares against the same path.
  pdir=$(cd "$dir" 2>/dev/null && pwd -P) || pdir=$dir
  mutates_repo "$cmd" || exit 0
fi

if [ -z "$agent" ]; then
  deny "リポジトリ内のファイル変更はメインスレッドから直接実行できません。Agent ツールでサブエージェントに委譲してください（例: Agent(subagent_type:\"general-purpose\", isolation:\"worktree\")）。読み取り・検索・ビルド・テストはメインスレッドで可。どうしても直接やる必要があるなら、ユーザーに CLAUDE_ENFORCE_OFF=1 での起動を依頼してください。"
fi

gd=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)
common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)
case "$common" in /*) ;; *) common=$(cd "$dir" && cd "$common" 2>/dev/null && pwd);; esac
[ -n "$gd" ] && [ "$gd" = "$common" ] && \
  deny "メインチェックアウト ($top) は変更できません。git worktree 内で作業してください。Agent は isolation:\"worktree\" で起動する、またはセッション側で EnterWorktree / claude --worktree を使ってください。"

exit 0
