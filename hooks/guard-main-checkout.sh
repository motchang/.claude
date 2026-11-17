#!/usr/bin/env bash
# PreToolUse guard for Edit / Write / NotebookEdit: a fence against Claude starting to
# edit a main checkout by mistake, not against attack. This comment is the one exact
# account of what it denies and what it lets through; README.md explains it in prose.
# It does not ask whether the main thread or a subagent is writing.
#
# Denied everywhere, outside ~/src and in a linked worktree too: a write to an opt-out
# switch, that is, any file named .claude/no-isolation and the list
# ~/.claude/hooks/no-isolation-repos, judged by the requested path and by the real one
# (a hard link to the list counts). Only the user edits them.
#
# Denied otherwise when all of these hold:
#  1. The real path is under the real ~/src. Symlinks on the path are resolved, one at
#     the end included. A path that does not exist yet belongs to the repo of its
#     nearest existing parent.
#  2. It is in the work tree of a git repo whose git-dir equals its git-common-dir, i.e.
#     not in a linked worktree. A submodule has its own git-dir equal to its common-dir
#     even when it was initialized inside a linked worktree, so a submodule counts as a
#     main checkout unless its superproject's git-dir and git-common-dir differ.
#  3. It is not inside .git: the real path is not under the git-dir or the
#     git-common-dir that git reports for it. With core.worktree set, git counts .git
#     as part of the work tree, and this rule still lets .git through.
#  4. Neither the repo nor, for a submodule, its superproject opts out. A repo nested in
#     an opted-out repo without being its submodule is judged on its own. Only the write
#     target counts, never the session's cwd.
#  5. It is not untracked and ignored (git check-ignore reads the index, so a tracked
#     file that matches an ignore rule stays guarded).
# For a submodule, 2 and 4 look one level up only.
#
# A repo opts out by a .claude/no-isolation file at its top, or by a line
# "<path> [until YYYY-MM-DD]" in ~/.claude/hooks/no-isolation-repos. The path may start
# with ~ and may go through a symlink (~/.claude or the directory under ~/src): both the
# entry and the repo are turned into real paths before they are compared. An entry with
# until holds through that day; the date is compared as a string and not checked. From a
# # to the end of the line, in the middle of a line too, is a comment. A list that cannot
# be read (missing, a broken symlink) counts as empty, and the deny says so.
#
# Passed silently: other tools, and whatever the hook cannot read (no jq, bad JSON, no
# path, git failing). A path that does not start with / passes as well, one that starts
# with ~ included, and the hook does not join it to the cwd. Such a path does not reach
# the hook in practice: before it runs a PreToolUse hook, Claude Code 2.1.326 expands ~,
# joins a relative path to the cwd and resolves .. (seen for Edit, Write and
# NotebookEdit). CLAUDE_ENFORCE_OFF=1 turns the hook off.
#
# A deny names the path it stopped, with the real HOME at its start written as ~: the
# repo's top for a main checkout, and the path as requested for a switch.

[ "${CLAUDE_ENFORCE_OFF:-}" = 1 ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

list=$HOME/.claude/hooks/no-isolation-repos

deny() {
  jq -nc --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# tilde <path>: the path with the real HOME at its start written as ~.
tilde() {
  local h
  h=$(cd -P -- "$HOME" 2>/dev/null && pwd -P)
  case $1 in "$h"/*) [ -n "$h" ] && { printf '%s' "~/${1#"$h"/}"; return; };; esac
  printf '%s' "$1"
}

# real <absolute path>: the physical path. The part that does not exist yet is
# appended as written to the nearest existing parent; a symlink at the end is followed.
real() {
  local d=$1 rest='' p
  while [ ! -d "$d" ]; do
    rest=/${d##*/}$rest; d=${d%/*}; [ -n "$d" ] || d=/
  done
  d=$(cd -P -- "$d" 2>/dev/null && pwd -P) || return 1
  p=${d%/}$rest
  if [ -L "$p" ]; then p=$(readlink -f -- "$p" 2>/dev/null) || p=${d%/}$rest; fi
  printf '%s\n' "$p"
}

# listed <dir>: the dir is in the list, and its until date (if any) is today or later.
listed() {
  local line p day today
  [ -r "$list" ] || return 1
  today=$(date +%F)
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    if [[ $line =~ ^(.*[^[:space:]])[[:space:]]+until[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
      line=${BASH_REMATCH[1]}; day=${BASH_REMATCH[2]}
      [[ $today > $day ]] && continue
    fi
    read -r p <<<"$line"
    case $p in '~') p=$HOME;; '~/'*) p=$HOME/${p#'~/'};; esac
    [ -n "$p" ] || continue
    [ -d "$p" ] && p=$(cd -P -- "$p" 2>/dev/null && pwd -P)
    [ "$p" = "$1" ] && return 0
  done <"$list"
  return 1
}

opted_out() { [ -f "$1/.claude/no-isolation" ] || listed "$1"; }

in=$(cat)
tool=$(printf '%s' "$in" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
case $tool in Edit|Write) key=file_path;; NotebookEdit) key=notebook_path;; *) exit 0;; esac
path=$(printf '%s' "$in" | jq -r --arg k "$key" '.tool_input[$k] // empty' 2>/dev/null) || exit 0
case $path in /*) ;; *) exit 0;; esac   # no path, or a relative one (~/... included)
rp=$(real "$path") || exit 0

# The opt-out switches themselves, by the requested path and by the real one.
list_rp=$(real "$list")
switch() {
  case $1 in */.claude/no-isolation) return 0;; esac
  [ "$1" = "$list_rp" ]
}
if switch "$path" || switch "$rp" || [ "$path" -ef "$list" ]; then
  deny "$(tilde "$path") は、どのリポジトリをフックの対象から外すかを決めるファイル（マーカー .claude/no-isolation か、除外リスト ~/.claude/hooks/no-isolation-repos）です。このファイルを書き換えるのはユーザーだけです。書き換えたいなら、ユーザーに頼んでください。"
fi

src=$(cd -P -- "$HOME/src" 2>/dev/null && pwd -P) || exit 0
case $rp in "$src"/*) ;; *) exit 0;; esac

dir=$rp
while [ ! -d "$dir" ]; do dir=${dir%/*}; [ -n "$dir" ] || dir=/; done
# --show-toplevel comes last: inside .git with no core.worktree it fails, and git has
# printed the other two by then.
{ read -r gitdir; read -r common; read -r top; } \
  < <(git -C "$dir" rev-parse --path-format=absolute --git-dir --git-common-dir --show-toplevel 2>/dev/null)
[ -n "$gitdir" ] && [ -n "$common" ] || exit 0   # not in a git repo, or git failed
case $rp in "$gitdir"/*|"$common"/*) exit 0;; esac   # inside .git
[ -n "$top" ] || exit 0   # no work tree
[ "$gitdir" = "$common" ] || exit 0   # a linked worktree

opted_out "$top" && exit 0
sup=$(git -C "$top" rev-parse --show-superproject-working-tree 2>/dev/null)
if [ -n "$sup" ]; then
  opted_out "$sup" && exit 0
  { read -r sgitdir; read -r scommon; } \
    < <(git -C "$sup" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null)
  [ -n "$scommon" ] && [ "$sgitdir" = "$scommon" ] || exit 0   # the superproject is a linked worktree
fi

git -C "$top" check-ignore -q -- "$rp" 2>/dev/null
[ $? = 1 ] || exit 0   # 0: untracked and ignored; 128: git failed

show=$(tilde "$top")
reason="メインチェックアウト $show のファイルを書き換えようとしたので、フックが止めました。リポジトリを書き換えるときは、サブエージェント（Agent(subagent_type:\"general-purpose\", isolation:\"worktree\")）に任せてください。このリポジトリを直接編集したいなら、ユーザーにマーカー $show/.claude/no-isolation を置いてもらってください。"
[ -r "$list" ] || reason="$reason 除外リスト ~/.claude/hooks/no-isolation-repos を読めなかった（ファイルがないか、symlink が切れている）ので、どのリポジトリも載っていないとみなしました。"
deny "$reason"
