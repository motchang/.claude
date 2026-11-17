#!/usr/bin/env bash
# Tests for guard-main-checkout.sh. Feeds PreToolUse JSON to the hook and checks its
# decision. HOME is a fresh temp dir with its own src/ and ~/.claude, so neither the
# real repositories nor the real no-isolation-repos list can change an outcome.
# The hook runs under the same bash as this script, so
# `/bin/bash guard-main-checkout.test.sh` exercises bash 3.2 on macOS.
# Usage: guard-main-checkout.test.sh [path/to/guard-main-checkout.sh]
# The default is the hook next to this file.
#
# Branches not tested, because no fixture here can reach them:
#  - `[ -n "$scommon" ] &&` in the superproject check. It matters only when git names a
#    superproject (--show-superproject-working-tree) and then fails in it, so that the
#    git-dir and the common-dir both come back empty. Without it the two empty strings
#    would compare equal and the write would be judged as in a main checkout; with it,
#    git failing lets the write through. Making git fail at that one step would take a
#    broken repo the other cases do not need.
set -u
hook=${1:-$(cd "$(dirname "$0")" && pwd -P)/guard-main-checkout.sh}
case $hook in /*) ;; *) hook=$PWD/$hook;; esac   # one case runs from another cwd
unset CLAUDE_ENFORCE_OFF XDG_CONFIG_HOME GIT_DIR GIT_WORK_TREE

# Not resolved on purpose: on macOS mktemp hands out /var/..., a symlink to
# /private/var/..., so every case also goes through a symlinked HOME. That also checks
# that a deny writes ~ for the real HOME, not for $HOME as given. RH is the real HOME,
# for the cases that spell a path the way it is written on a machine whose HOME is real.
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
HOME=$tmp
export HOME
RH=$(cd -P -- "$HOME" && pwd -P)
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_NOSYSTEM=1

S=$HOME/src
g() { git -c protocol.file.allow=always "$@"; }
repo() {  # repo <dir>: a repo with one tracked file a.txt
  g init -q "$1" && echo a >"$1/a.txt" && g -C "$1" add a.txt && g -C "$1" commit -qm init
}
# subrepo <dir>: a repo with a.txt and the submodule lib, and a linked worktree w under
# .claude/worktrees in which the submodule is initialized.
subrepo() {
  repo "$1"
  g -C "$1" submodule add -q "$S/sublib" lib >/dev/null 2>&1
  g -C "$1" commit -qm sub
  g -C "$1" worktree add -q -b w "$1/.claude/worktrees/w" 2>/dev/null
  g -C "$1/.claude/worktrees/w" submodule update --init -q >/dev/null 2>&1
}

# main: an ordinary main checkout, with an ignore file and a tracked file it matches,
# a tracked symlink that points out of ~/src, and a broken one that would.
repo "$S/main"
printf 'node_modules/\n*.log\n' >"$S/main/.gitignore"
echo k >"$S/main/keep.log"
echo t >"$HOME/outside-target.txt"
ln -s "$HOME/outside-target.txt" "$S/main/out-link"
g -C "$S/main" add -f .gitignore keep.log out-link && g -C "$S/main" commit -qm ignore
ln -s "$HOME/nowhere/x.txt" "$S/main/broken-link"
g -C "$S/main" worktree add -q -b nest "$S/main/.claude/worktrees/x" 2>/dev/null
g -C "$S/main" worktree add -q -b away "$S/elsewhere/wt" 2>/dev/null

# super has a submodule; super2 the same, with a marker at the superproject's top;
# listsup the same, listed. In each, the worktree w has the submodule initialized.
repo "$S/sublib"
for s in super super2 listsup; do subrepo "$S/$s"; done
mkdir -p "$S/super2/.claude" && : >"$S/super2/.claude/no-isolation"

# cwt sets core.worktree to its own top, so git counts .git as part of the work tree.
# It has a submodule, whose git dir lives in .git/modules/lib.
# The two cases that write into a submodule's git dir (.git/modules/lib, in super and in
# cwt) pass even without the inside-.git rule, because check-ignore exits 128 there; the
# core.worktree cases on .git/config and .git/info/exclude are the ones that test it.
repo "$S/cwt"
g -C "$S/cwt" submodule add -q "$S/sublib" lib >/dev/null 2>&1
g -C "$S/cwt" commit -qm sub
g -C "$S/cwt" config core.worktree "$S/cwt"
# sepgit holds only a .git whose core.worktree is septree, which has no .git of its own:
# from sepgit git names septree as the top, and git run in septree fails, so check-ignore
# exits 128 there after rev-parse has succeeded.
g init -q "$S/sepgit" && mkdir -p "$S/septree" && g -C "$S/sepgit" config core.worktree "$S/septree"
# bareouter holds the repo inner, which has core.bare set, so git finds no work tree for
# inner. Its case runs the hook from bareouter: past the no-work-tree rule, git -C with
# an empty top would stay in that cwd and answer check-ignore for the outer repo.
repo "$S/bareouter" && repo "$S/bareouter/inner" && g -C "$S/bareouter/inner" config core.bare true

repo "$S/marked"
mkdir -p "$S/marked/.claude" && : >"$S/marked/.claude/no-isolation"
# dirmark has a directory where the marker would be. Only a file counts as the marker.
repo "$S/dirmark"
mkdir -p "$S/dirmark/.claude/no-isolation"

for r in listed expired future today conf private lastline hash2; do repo "$S/$r"; done
# listed ignores nested/, an independent repo inside it.
echo 'nested/' >"$S/listed/.gitignore"
repo "$S/listed/nested"
# ~/.claude is a symlink to the conf repo, and its list a symlink into a private repo,
# as on the real machine. Both repos are listed, so only the rule for the list itself
# can deny a write to it. The last line has no newline.
ln -s "$S/conf" "$HOME/.claude"
mkdir -p "$S/conf/hooks"
cat >"$S/private/no-isolation-repos" <<EOF
# opt-out list
~/.claude
~/src/private
~/src/listsup
~/src/listed/   # a trailing slash and a comment
~/src/hash2 # a comment # with a second hash
~/src/expired until 2000-01-01
  ~/src/future	until 2999-12-31
~/src/today until $(date +%F)
EOF
printf '%s' '~/src/lastline' >>"$S/private/no-isolation-repos"
ln -s "$S/private/no-isolation-repos" "$S/conf/hooks/no-isolation-repos"
ln "$S/private/no-isolation-repos" "$HOME/hardlist"

repo "$HOME/outside"
mkdir -p "$S/plain/dir"
ln -s "$S/main" "$HOME/link"
ln -s "$S/main/a.txt" "$HOME/linkfile"
# A marker reached through a symlinked .claude dir, and a symlink to a marker.
mkdir "$HOME/plaindir" "$HOME/sl"
ln -s "$HOME/plaindir" "$HOME/sl/.claude"
ln -s "$S/marked/.claude/no-isolation" "$HOME/marker-link"

# A HOME with no src/ and a repo elsewhere in it, for the hook to run with.
NH=$HOME/nosrc-home
repo "$NH/elsewhere/main"

# A PATH with no jq, and one with jq but no git.
mkdir "$HOME/nojq" "$HOME/nogit"
for c in jq cat date readlink; do ln -s "$(command -v "$c")" "$HOME/nogit/$c"; done

# A fixture that failed to build would let some cases pass for the wrong reason.
missing() { echo "fixture missing: $*" >&2; exit 1; }
for f in main/.claude/worktrees/x/a.txt elsewhere/wt/a.txt \
  super/lib/a.txt super2/lib/a.txt listsup/lib/a.txt \
  super/.claude/worktrees/w/lib/a.txt listsup/.claude/worktrees/w/lib/a.txt \
  super2/.claude/no-isolation marked/.claude/no-isolation marked/a.txt \
  listed/a.txt listed/nested/a.txt expired/a.txt future/a.txt today/a.txt \
  conf/a.txt private/a.txt lastline/a.txt hash2/a.txt dirmark/a.txt \
  cwt/a.txt cwt/lib/a.txt cwt/.git/config cwt/.git/info/exclude cwt/.git/modules/lib/config \
  super/.git/modules/lib/config bareouter/a.txt bareouter/inner/a.txt private/no-isolation-repos; do
  [ -f "$S/$f" ] || missing "$S/$f"
done
for l in "$HOME/.claude" "$S/conf/hooks/no-isolation-repos" "$HOME/link" "$HOME/linkfile" \
  "$S/main/out-link" "$S/main/broken-link" "$HOME/sl/.claude" "$HOME/marker-link"; do
  [ -L "$l" ] || missing "symlink $l"
done
[ -e "$S/main/broken-link" ] && missing "broken-link is not broken"
[ -d "$S/dirmark/.claude/no-isolation" ] || missing "the directory in place of dirmark's marker"
[ -f "$HOME/.claude/hooks/no-isolation-repos" ] || missing "the list through ~/.claude"
[ -f "$HOME/outside-target.txt" ] || missing "the target of out-link"
[ "$HOME/hardlist" -ef "$S/private/no-isolation-repos" ] || missing "hard link to the list"
[ -n "$(tail -c 1 "$S/private/no-isolation-repos")" ] || missing "a last line with no newline"
g -C "$S/main" ls-files --error-unmatch out-link >/dev/null 2>&1 || missing "out-link tracked"
g -C "$S/listed" check-ignore -q nested/ || missing "listed ignoring nested/"
g -C "$HOME/outside" rev-parse --git-dir >/dev/null 2>&1 || missing "a repo at ~/outside"
[ -f "$NH/elsewhere/main/a.txt" ] || missing "the repo in the HOME with no src/"
[ -e "$NH/src" ] && missing "src/ in the HOME that should have none"
"$HOME/nogit/jq" -n 1 >/dev/null 2>&1 || missing "jq in the PATH with no git"
[ -e "$HOME/nogit/git" ] && missing "git in the PATH with no git"
# With core.worktree, git must see a work tree from inside .git, or the .git rule would
# not be the one letting the cwt cases through.
g -C "$S/cwt/.git" rev-parse --show-toplevel >/dev/null 2>&1 || missing "core.worktree in cwt"
g -C "$S/sepgit" rev-parse --show-toplevel >/dev/null 2>&1 || missing "core.worktree in sepgit"
g -C "$S/septree" check-ignore -q -- "$S/sepgit/notes.txt" 2>/dev/null
[ $? = 128 ] || missing "check-ignore failing in septree"
g -C "$S/bareouter/inner" rev-parse --git-dir >/dev/null 2>&1 || missing "a repo at bareouter/inner"
g -C "$S/bareouter/inner" rev-parse --show-toplevel >/dev/null 2>&1 && missing "a work tree for bareouter/inner"
# A submodule initialized in a worktree must have its git-dir equal to its common-dir,
# or the worktree rule alone would let it through.
for d in super/.claude/worktrees/w/lib listsup/.claude/worktrees/w/lib; do
  { read -r gd; read -r gc; } \
    < <(g -C "$S/$d" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null)
  case $gd in */.git/worktrees/w/modules/lib) ;; *) missing "git-dir of $S/$d: $gd";; esac
  [ "$gd" = "$gc" ] || missing "git-dir and common-dir of $S/$d differ: $gd $gc"
done

pass=0 fail=0
# expect <label> <glob>: the last deny reason matches the glob.
expect() {
  case $LAST_REASON in
    $2) pass=$((pass+1)); printf 'PASS  %s\n' "$1";;
    *) fail=$((fail+1)); printf 'FAIL  %s  (reason: %s)\n' "$1" "$LAST_REASON";;
  esac
}
# expect_no <label> <glob>: the last deny reason does not match the glob.
expect_no() {
  case $LAST_REASON in
    $2) fail=$((fail+1)); printf 'FAIL  %s  (reason: %s)\n' "$1" "$LAST_REASON";;
    *) pass=$((pass+1)); printf 'PASS  %s\n' "$1";;
  esac
}

# check <label> <allow|deny> <stdin> [VAR=value ...]: run the hook, compare the decision.
check() {
  local label=$1 want=$2 input=$3 out rc err dec reason got
  shift 3
  out=$(printf '%s' "$input" | env "$@" "$BASH" "$hook" 2>"$HOME/stderr"); rc=$?
  err=$(cat "$HOME/stderr")
  dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
  if [ "$rc" != 0 ] || [ -n "$err" ]; then got="error(rc=$rc err=${err:0:200})"
  elif [ -z "$out" ]; then got=allow
  elif [ "$dec" = deny ] && [ -n "$reason" ] && [[ $reason != *CLAUDE_ENFORCE_OFF* ]] \
    && [ "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)" = PreToolUse ]; then got=deny
  else got="bad-output(${out:0:160})"
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf 'PASS  %s\n' "$label"
  else
    fail=$((fail+1)); printf 'FAIL  %s  (want %s, got %s)\n' "$label" "$want" "$got"
  fi
  LAST_REASON=$reason
}

# j <tool> <path> [cwd]: the hook's input for a write to <path>.
j() {
  local key=file_path; [ "$1" = NotebookEdit ] && key=notebook_path
  jq -nc --arg t "$1" --arg k "$key" --arg p "$2" --arg c "${3:-/}" \
    '{session_id:"s",hook_event_name:"PreToolUse",cwd:$c,tool_name:$t,tool_input:{($k):$p}}'
}

check "main: Edit a tracked file"                   deny  "$(j Edit "$S/main/a.txt")"
expect "main: reason names the repo with ~, a subagent and the marker" \
  'メインチェックアウト ~/src/main のファイルを*Agent(subagent_type:"general-purpose", isolation:"worktree")*マーカー ~/src/main/.claude/no-isolation を*'
expect_no "main: list readable, reason says nothing of it" '*読めなかった*'
expect_no "main: reason does not tell how to write to another repo" '*worktree add*'
check "main: Write a new untracked file"            deny  "$(j Write "$S/main/new.txt")"
check "main: Write under new dirs, not ignored"     deny  "$(j Write "$S/main/newdir/sub/x.txt")"
check "main: Write an ignored file"                 allow "$(j Write "$S/main/debug.log")"
check "main: Write under a new ignored dir"         allow "$(j Write "$S/main/node_modules/a/b.js")"
check "main: tracked file matching an ignore rule"  deny  "$(j Edit "$S/main/keep.log")"
check "main: .github is not .git"                   deny  "$(j Write "$S/main/.github/workflows/ci.yml")"
check "main: a broken symlink pointing out of ~/src" deny "$(j Edit "$S/main/broken-link")"
check "main: GIT_DIR set in the environment"        deny  "$(j Edit "$S/main/a.txt")" GIT_DIR=/nonexistent
check "worktree under .claude/worktrees"            allow "$(j Edit "$S/main/.claude/worktrees/x/a.txt")"
check "worktree under .claude/worktrees, new file"  allow "$(j Write "$S/main/.claude/worktrees/x/n/new.txt")"
check "worktree elsewhere in ~/src"                 allow "$(j Edit "$S/elsewhere/wt/a.txt")"
check "inside .git"                                 allow "$(j Write "$S/main/.git/info/exclude")"
check "inside .git, new dir"                        allow "$(j Write "$S/main/.git/newdir/x")"
check "inside .git/modules of a submodule"          allow "$(j Write "$S/super/.git/modules/lib/config")"
check "core.worktree: Edit .git/config"             allow "$(j Edit "$S/cwt/.git/config")"
check "core.worktree: Write .git/info/exclude"      allow "$(j Write "$S/cwt/.git/info/exclude")"
check "core.worktree: the submodule's git dir"      allow "$(j Edit "$S/cwt/.git/modules/lib/config")"
check "core.worktree: a tracked file"               deny  "$(j Edit "$S/cwt/a.txt")"
check "core.worktree: a file in the submodule"      deny  "$(j Edit "$S/cwt/lib/a.txt")"
check "beside a .git whose work tree is elsewhere"  allow "$(j Write "$S/sepgit/notes.txt")"
cd "$S/bareouter" || exit 1
check "core.bare: no work tree, hook run from the outer repo" \
                                                    allow "$(j Edit "$S/bareouter/inner/a.txt" "$S/bareouter")"
cd "$OLDPWD" || exit 1
check "submodule file"                              deny  "$(j Edit "$S/super/lib/a.txt")"
check "submodule, superproject has the marker"      allow "$(j Edit "$S/super2/lib/a.txt")"
check "submodule, superproject listed"              allow "$(j Edit "$S/listsup/lib/a.txt")"
check "submodule initialized in a worktree"         allow "$(j Edit "$S/super/.claude/worktrees/w/lib/a.txt")"
check "submodule in a worktree, new file"           allow "$(j Write "$S/super/.claude/worktrees/w/lib/n/new.txt")"
check "submodule in a worktree of a listed repo"    allow "$(j Edit "$S/listsup/.claude/worktrees/w/lib/a.txt")"
check "repo with the marker"                        allow "$(j Edit "$S/marked/a.txt")"
check "a directory in place of the marker"          deny  "$(j Edit "$S/dirmark/a.txt")"
check "the marker itself"                           deny  "$(j Write "$S/marked/.claude/no-isolation")"
expect "marker: reason says only the user edits it" '*/src/marked/.claude/no-isolation は、*ユーザーだけ*'
check "the marker, spelled from the real HOME"      deny  "$(j Write "$RH/src/marked/.claude/no-isolation")"
expect "marker: reason names it with ~ as requested" \
  '~/src/marked/.claude/no-isolation は、*ユーザーだけ*書き換えたいなら*'
check "a new marker in an unmarked repo"            deny  "$(j Write "$S/main/.claude/no-isolation")"
expect "new marker: denied as a switch, not as main" '*ユーザーだけ*'
check "a new marker in a worktree"                  deny  "$(j Write "$S/main/.claude/worktrees/x/.claude/no-isolation")"
check "a new marker outside ~/src"                  deny  "$(j Write "$HOME/notes/.claude/no-isolation")"
check "a marker through a symlinked .claude dir"    deny  "$(j Write "$HOME/sl/.claude/no-isolation")"
check "a symlink to a marker, outside ~/src"        deny  "$(j Edit "$HOME/marker-link")"
expect "symlink to a marker: denied as a switch" '*/marker-link は、*ユーザーだけ*'
check "a name like the marker: no-isolation.md"     allow "$(j Write "$HOME/notes/no-isolation.md")"
check "a name like the marker: no .claude dir"      allow "$(j Write "$HOME/notes/no-isolation")"
check "a name like the marker: .claude/no-isolation.bak" allow "$(j Write "$HOME/notes/.claude/no-isolation.bak")"
check "listed repo, no expiry"                      allow "$(j Edit "$S/listed/a.txt")"
check "listed repo, expired"                        deny  "$(j Edit "$S/expired/a.txt")"
check "listed repo, not yet expired"                allow "$(j Edit "$S/future/a.txt")"
check "listed repo, expires today"                  allow "$(j Edit "$S/today/a.txt")"
check "listed on the last line, no newline"         allow "$(j Edit "$S/lastline/a.txt")"
check "listed on a line with two #s"                allow "$(j Edit "$S/hash2/a.txt")"
check "repo nested in a listed repo, ignored there" deny  "$(j Edit "$S/listed/nested/a.txt")"
check "listed as ~/.claude, written via ~/.claude"  allow "$(j Edit "$HOME/.claude/a.txt")"
check "listed as ~/.claude, written via real path"  allow "$(j Edit "$S/conf/a.txt")"
check "the list via ~/.claude"                      deny  "$(j Edit "$HOME/.claude/hooks/no-isolation-repos")"
check "the list via ~/.claude, from the real HOME"  deny  "$(j Edit "$RH/.claude/hooks/no-isolation-repos")"
expect "the list: reason names it with ~ as requested" '~/.claude/hooks/no-isolation-repos は、*ユーザーだけ*'
check "the list via the repo's symlink"             deny  "$(j Edit "$S/conf/hooks/no-isolation-repos")"
check "the list at its real path"                   deny  "$(j Edit "$S/private/no-isolation-repos")"
check "a hard link to the list, outside ~/src"      deny  "$(j Edit "$HOME/hardlist")"
check "outside ~/src (a repo)"                      allow "$(j Edit "$HOME/outside/a.txt")"
check "outside ~/src (no repo)"                     allow "$(j Write "$HOME/notes.txt")"
check "in ~/src but outside git"                    allow "$(j Write "$S/plain/dir/x.txt")"
check "no ~/src in HOME: a repo elsewhere in HOME"  allow "$(j Edit "$NH/elsewhere/main/a.txt")" HOME="$NH"
check "symlinked dir outside ~/src into main"       deny  "$(j Edit "$HOME/link/a.txt")"
check "symlinked dir into main, ignored file"       allow "$(j Write "$HOME/link/x.log")"
check "symlinked file outside ~/src into main"      deny  "$(j Edit "$HOME/linkfile")"
check "tracked symlink in main to outside ~/src"    allow "$(j Edit "$S/main/out-link")"
check "NotebookEdit in main"                        deny  "$(j NotebookEdit "$S/main/n.ipynb")"
check "NotebookEdit in a worktree"                  allow "$(j NotebookEdit "$S/elsewhere/wt/n.ipynb")"
check "NotebookEdit in a listed repo"               allow "$(j NotebookEdit "$S/listed/n.ipynb")"
check "other tools are not judged"                  allow "$(j Read "$S/main/a.txt")"
check "broken JSON"                                 allow '{"tool_name":"Edit","tool_input":'
check "not an object"                               allow '[1,2]'
check "empty input"                                 allow ''
check "no file_path, cwd in main"                   allow "$(jq -nc --arg c "$S/main" '{cwd:$c,tool_name:"Edit",tool_input:{}}')"
check "relative path, cwd in main"                  allow "$(j Edit a.txt "$S/main")"
check "path starting with ~, cwd in main"           allow "$(j Write '~/notes.txt' "$S/main")"
check "~/src/main/a.txt is not expanded"            allow "$(j Edit '~/src/main/a.txt' "$S/main")"
check "relative path without a cwd"                 allow '{"tool_name":"Edit","tool_input":{"file_path":"a.txt"}}'
check "relative path and a relative cwd"            allow "$(j Edit a.txt nope)"
check "CLAUDE_ENFORCE_OFF=1"                        allow "$(j Edit "$S/main/a.txt")" CLAUDE_ENFORCE_OFF=1
check "jq missing"                                  allow "$(j Edit "$S/main/a.txt")" PATH="$HOME/nojq"
check "git missing"                                 allow "$(j Edit "$S/main/a.txt")" PATH="$HOME/nogit"

# The list cannot be read: it counts as empty, and the deny says so. Each case puts
# the list back before the next one.
mv "$S/conf/hooks/no-isolation-repos" "$HOME/list-link.bak"
check "list missing: a listed repo is denied"       deny  "$(j Edit "$S/listed/a.txt")"
expect "list missing: reason says it was not read"  '*~/.claude/hooks/no-isolation-repos を読めなかった*'
check "list missing: the marker still opts out"     allow "$(j Edit "$S/marked/a.txt")"
check "list missing: creating it is denied"         deny  "$(j Write "$HOME/.claude/hooks/no-isolation-repos")"
check "list missing: creating it via the repo path" deny  "$(j Write "$S/conf/hooks/no-isolation-repos")"
expect "list missing: denied as a switch, not as main" '*ユーザーだけ*'
mv "$HOME/list-link.bak" "$S/conf/hooks/no-isolation-repos"
mv "$S/private/no-isolation-repos" "$HOME/list.bak"
check "list symlink broken: a listed repo is denied" deny "$(j Edit "$S/listed/a.txt")"
expect "list symlink broken: reason says it was not read" '*~/.claude/hooks/no-isolation-repos を読めなかった*'
mv "$HOME/list.bak" "$S/private/no-isolation-repos"
check "list back: the listed repo passes again"     allow "$(j Edit "$S/listed/a.txt")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
