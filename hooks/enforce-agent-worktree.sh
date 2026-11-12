#!/usr/bin/env bash
# PreToolUse guard (Bash/Edit/Write/NotebookEdit). Two rules, for changes to a git work tree:
#   1. Mutating work must run inside a subagent (hook input carries agent_id).
#   2. It must not land in a main checkout (any repo's), only in a linked worktree.
# Bash is read structured -- a leading literal cd chain, git -C/--work-tree/--git-dir,
# GIT_*= (also export/env), tool dir flags, wrappers -- or, for anything harder ($ ` \ <<
# eval sh -c ...), opaque: cwd plus every cd target, every path word of a mutating command.
# A destructive verb on /, ~ or a parent of a main checkout is denied. Over 16384 chars
# (or 64 dirs / 2000 paths) any redirect or writing word is denied as too long.
# Quoted heredoc bodies are dropped before either reading, only for allowlisted shapes
# (cat >/tee into a literal path, gh ... "$(cat <<'D' ...)"; see strip_heredocs).
# Opt out: ~/.claude/hooks/no-isolation-repos ("<path> [until YYYY-MM-DD]") or a
# .claude/no-isolation file at a main checkout's top (a regular file named exactly so, in a
# real .claude dir, neither a symlink). Both count on the cwd / file dir and on each Bash
# target in an opted-out main checkout (listed, or the marker at its top) that no main
# checkout without an opt-out holds. A cwd in a linked worktree counts by its main
# checkout, so an agent there is let through for everything, as in the main checkout
# itself (list and marker alike). A marker in a linked worktree alone opts nothing out, nor
# does one beside a bare or separate git dir: from such a repo's worktrees no main top is
# found, and none counts.
# The opt-out clears no target of a command (NOEX) that has the lowercase whole word clean
# or submodule anywhere (quotes and backslashes dropped, so -m "clean up", make clean and
# submodule update lose it too), a verb or git subcommand from $ or `, or GIT_CONFIG*=.
# Nor does it cover the opted-out root removed (structured reading only), a parent removed
# that holds a main checkout of the cwd or the cd chain, or, once it has cleared a path, a
# writing command with an unresolved target (R2U, outside a repo too). git -c alias.*/
# include.*/includeIf.* (also --config-env), GIT_CONFIG*= and a git subcommand from $ or `
# make the command an unresolved writer, read-only use too (GIT_CONFIG_GLOBAL=x git status,
# git $v), from a cwd in any repo, agent or main thread.
# From a guarded cwd with no agent, rule 1's original reading still refuses git subcommands
# into an opted-out repo; other writers (rm, touch, redirects) into it pass, as Write does.
# SELF refuses, in any letter case, a Bash writer whose text names the list or the marker,
# an Edit/Write to either, and a writer whose target is the .claude dir that holds a main
# checkout's marker (rm -rf, mv, cp -r of it). Other ways of removing a marker pass (rm of
# a name APFS folds to it, git rm / stash -u / switch --orphan, removal from an opted-out
# cwd): they only fail safe. CLAUDE_ENFORCE_OFF=1 turns the hook off.
# A symlink that a writer goes through (a redirect, tee, cp's destination and, for a plain
# cp into a dir, <dir>/<source's name>, a hard ln's source, Edit/Write, chmod without -h
# ...; not rm, mv, unlink, ln -s's names, chmod -h) is judged at its target too: one
# readlink -f per command resolves every such link, the whole chain as far as the kernel
# follows it, a dangling last hop included. Over 256 links is too long. An answer that
# does not map one line per link, or that is still a link (a loop, a chain readlink gives
# up on), denies (R2U / R1). A glob is never expanded: a path with * ? [ ] ^ #, ~ past its
# start, or in a command with a zsh pattern the lexer splits (a ( glued to a word or
# opening one after a word or > / >>, <N-M>) gets no opt-out, the list and the marker
# alike, since a link may sit among its matches. From a cwd outside the opted-out repo this
# denies what HEAD let through, failing safe: ( in quotes or comments (-m "feat(api): x",
# # note (x)), if (true), tee >(cat), and names like L/a[1].txt, L/new~, L/v<1-2>.
# ln -s reads a relative target from the link's dir as well as from the cwd. So a link
# brought in from outside (mv, cp -R / -P, tar -x) is caught when written through, not
# when it arrives.
# Not caught, links: a glob write into W or any unexempt dir through a link there (W/l? ->
# M, as on HEAD), a link made earlier in the same command, a write through a hard link
# that already exists (it looks like a plain file), `link SRC DST` (not a known
# writer, as on HEAD), and a zsh (…) glob after >| >>| &>| 1>| (cd M && echo pwn >|
# (f|x) from W, as on HEAD, marker or not).
# Not caught: writers not listed (gzip, sort -o, ditto, python -c), rm -rf of a
# main checkout given as a direct path when that checkout is not the cwd's or on the cd
# chain (so a repo nested in an opted-out one, removed with its parent dir), GIT_* values
# resolved against the cd base instead of the -C dir (cd D && GIT_WORK_TREE=../M git -C L
# checkout), git's env set without a GIT_*= word (printf -v, read <<<), opaque
# `x=$y; rm -rf <opted-out root>` (also git -C <root>/inner/.. add -A), a git subcommand
# from a brace or glob (cl{ean,}, cl?an, {checkout,}), printf -v GIT_CONFIG_PARAMETERS,
# aliases from config files (also HOME= another .gitconfig, git config alias.x clean then
# git x), --exec-path=<dir>, the script run by bash -c / sh -c (bash -c 'git -C M clean
# -ffdx' passes; only ; & | ( inside it split off pieces that are judged), a script built
# at run time (bash -c "$s"). A marker made at a main checkout's top through a path not
# followed (a name built from a variable from a cwd outside every repo, a writer not
# listed) counts from the next command on, for cwds in that checkout and its worktrees
# and as a target from any cwd.
set -uo pipefail
set -f   # no globbing: arguments are inspected as written, never expanded
export LC_ALL=C
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

decided=0
deny() {  # printf, not jq: the deny must come out even when jq is missing
  local r=${1//\\/\\\\}; decided=1; r=${r//\"/\\\"}
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$r"
  exit 0
}
allow() { decided=1; exit 0; }
# A crash or set -u abort must not turn into an allow.
trap '[ "$decided" = 1 ] || deny "フックの内部エラーで判定できませんでした。コマンドを単純にして再実行してください。"' EXIT
[ "${CLAUDE_ENFORCE_OFF:-}" = "1" ] && allow
command -v jq >/dev/null 2>&1 || deny "jq が見つからないため判定できません。jq をインストールしてください。"

in=$(cat)
[ -n "${HOME:-}" ] || deny "HOME が未設定のため判定できません。"
printf '%s' "$in" | jq -e '(.tool_name|type=="string") and (.tool_name!="Bash" or (.tool_input.command|type=="string"))' >/dev/null 2>&1 \
  || deny "フックの入力（tool_name / command）を読めないため判定できません。"
q() { printf '%s' "$in" | jq -r "$1 // \"\"" 2>/dev/null; }
tool=$(q '.tool_name'); agent=$(q '.agent_id'); cwd=$(q '.cwd')
path=$(q '.tool_input.file_path // .tool_input.notebook_path'); cmd=$(q '.tool_input.command'); cmd_raw=$cmd
case $path in ''|/*) ap=$path;; *) ap=$cwd/$path;; esac   # file_path is relative to the cwd

hint="※読み取りのつもりで拒否された場合は誤検知の可能性が高い（コマンド文字列中の > < | やバッククォート、変数展開したパスをリダイレクトと誤認する）。ファイルの書き込みは Bash ではなく Write/Edit ツールでリテラルな絶対パスに行い、新規ディレクトリ配下へ書く前に mkdir -p で親を作っておくと通る。※Bash の行き先は先頭の cd <リテラルなパス> の連鎖と git -C/--work-tree/--git-dir のリテラルで判定する。変数・バックスラッシュ・eval・sh -c・xargs・cd -・pushd を含むと cwd と全 cd 先で判定する。"
R1="リポジトリ内のファイル変更はメインスレッドから直接実行できません。Agent ツールでサブエージェントに委譲してください（例: Agent(subagent_type:\"general-purpose\", isolation:\"worktree\")）。読み取り・検索・ビルド・テストはメインスレッドで可。どうしても直接やる必要があるなら、ユーザーに CLAUDE_ENFORCE_OFF=1 での起動を依頼してください。$hint"
R2="メインチェックアウトは変更できません。git worktree 内で作業してください。Agent は isolation:\"worktree\" で起動する、またはセッション側で EnterWorktree / claude --worktree を使ってください。$hint"
R2U="メインチェックアウトを変更しないことを確認できません（変数・cd -・pushd・ブレース展開などで行き先が決まらない）。リテラルな絶対パスで書き直してください。$hint"
LONG="コマンドが長すぎて判定できません（16384 文字・64 ディレクトリ・2000 パス・256 シンボリックリンク・1 コマンド 64 語位置のいずれかを超えた）。分割してください。"
SELF="オプトアウトの指定（.claude/no-isolation と ~/.claude/hooks/no-isolation-repos）はユーザーだけが編集できます。必要ならユーザーに編集を依頼してください。"

# mut_ev <cmd>: quotes and backslashes dropped, any redirect (bar /dev/null and fd dups)
# or a writing word remains. The coarse reading for what is not parsed word by word.
# grep reads to the end (no -q): under pipefail an early exit kills sed with SIGPIPE
# (141) and turns a match into "no writer".
mut_ev() {
  printf '%s' "$1" | tr -d "\\\\\"'" | sed -E -e 's/[0-9]*[<>]&[0-9-]+//g' -e 's/[0-9&]*>>?[[:space:]]*\/dev\/(null|stdout|stderr|tty)//g' \
    | grep -E '[<>]|(^|[^[:alnum:]_.-])(rm|rmdir|mv|cp|rsync|touch|mkdir|ln|unlink|chmod|chown|chgrp|tee|dd|patch|truncate|shred|install|sed|perl|ruby|gofmt|tar|unzip|curl|wget|find|git|npm|pnpm|yarn|bun|npx|rimraf|cargo|go|make|gmake|eval|exec|source|xargs|sh|bash|zsh|sudo)([^[:alnum:]_.-]|$)' >/dev/null
}

# ------------------------------------------------------------ repository facts

# info <physical dir>: IM=1 if it lies in a main checkout (absolute-git-dir equals the
# common dir; a linked worktree, even nested in M, is not main), IMT the main checkout's
# top, IMC the common dir. Cached; more than 64 distinct dirs sets TOO_MANY.
IK=(); IV=(); TOO_MANY=0
info() {
  local i out
  for ((i=0; i<${#IK[@]}; i++)); do [ "${IK[i]}" = "$1" ] && { set_info "${IV[i]}"; return; }; done
  if [ ${#IK[@]} -ge 64 ]; then TOO_MANY=1; IM=1; IMT=""; IMC=""; return; fi
  out=$(cd -P -- "$1" 2>/dev/null || exit 0
    { IFS= read -r g; IFS= read -r c; IFS= read -r t; } <<<"$(git rev-parse --path-format=absolute --absolute-git-dir --git-common-dir --show-toplevel 2>/dev/null)"
    [ -n "${g:-}" ] && [ -n "${c:-}" ] || exit 0
    cd -P -- "$g" 2>/dev/null && g=$PWD; cd -P -- "$c" 2>/dev/null && c=$PWD
    if [ "$g" = "$c" ]; then m=1; [ -n "${t:-}" ] || t=${c%/.git}; else m=0; t=${c%/*}; fi
    printf '%s\t%s\t%s' "$m" "$t" "$c")
  IK+=("$1"); IV+=("$out"); set_info "$out"
}
set_info() { IM=0 IMT="" IMC=""; [ -n "$1" ] && IFS=$'\t' read -r IM IMT IMC <<<"$1"
  return 0; }

# ------------------------------------------------------------ path collection

joinp() { case $2 in /*) JP=$2;; '~') JP=$HOME;; '~/'*) JP=$HOME/${2#'~/'};; *) JP=$1/$2;; esac; }
lexnorm() { local IFS=/ p o=""; for p in $1; do case $p in ''|.) ;; ..) o=${o%/*};; *) o=$o/$p;; esac; done; LEX=${o:-/}; }

# add_path <word> <base> <destructive>: queue a path for the batch check. A glob is cut
# back to the directory it expands in and is never expanded here. Its matches are unknown
# (a link among them, zsh's ** and (a|b), the shell's locale), so a globbed path gets no
# opt-out (PX=1): * ? [ ] ^ #, ~ past the start, or NXC for the whole command (zsh
# patterns the lexer splits, below). What cannot be read literally sets UNRES.
PS=(); PD=(); PF=(); PX=(); FOLLOW=1; UNRES=0; GENV=(); NXC=0
add_path() {
  local w=$1 x=$NXC
  [ ${#PS[@]} -ge 2000 ] && { TOO_MANY=1; return; }
  case $w in ''|'{}'|*://*) return;; *'$'*|*'`'*|'~'[!/]*|*'{'*,*'}'*|*'{'*..*'}'*) UNRES=1; return;; esac
  case $w in *[]*?[^#]*) x=1;; esac
  case ${w#'~'} in *'~'*) x=1;; esac
  case $w in *[*?[{]*) w=${w%%[*?[{]*}; case $w in */*) w=${w%/*}/;; *) w=.;; esac;; esac
  case $w in '~'*) PS+=("$2/$w"); PD+=("$3"); PF+=("$FOLLOW"); PX+=("$x");; esac
  joinp "$2" "$w"; PS+=("$JP"); PD+=("$3"); PF+=("$FOLLOW"); PX+=("$x")
}
pathy() { case $1 in /*|*/*|.|..|'~'*) return 0;; esac; return 1; }

# ------------------------------------------------------------ verbs

has_after() { local j p; for ((j=$1+1; j<NW; j++)); do for p in "${@:2}"; do case ${WORDS[j]} in $p) return 0;; esac; done; done; return 1; }
sub_after() { local j; SUB=""; for ((j=$1+1; j<NW; j++)); do case ${WORDS[j]} in
  -C|-c|-f|-j|-e|-p|-P|-D|--file|--git-dir|--work-tree|--manifest-path|--exec-path|--prefix|--cwd|--dir|--chdir|--namespace|--super-prefix|--config-env) j=$((j+1));;
  -*) ;; *) SUB=${WORDS[j]}; SUBI=$j; return;; esac; done; SUBI=$NW; }

each_base() { local b; [ $TOO_MANY = 1 ] && return 0; for b in "${BASES[@]}"; do add_path "$1" "$b" "$2"; done; }

git_verb() {
  local k=$1 j w v b cur mut=0 hadc out=0
  sub_after "$k"; local si=$SUBI
  # clean -x and submodule (foreach, deinit) reach nested repos no target lookup sees;
  # such a command gets no help from the opt-out (NOEX; the word scan in can_ex
  # also catches them). A subcommand from a variable could be anything: an
  # unresolved writer.
  case $SUB in clean|submodule) NOEX=1;; *'$'*|*'`'*) MUT=1; UNRES=1; NOEX=1;; esac
  # An alias (or an included config file) set on the command line makes any subcommand
  # a writer, to a place this reading cannot follow.
  for ((j=k+1; j<si; j++)); do w=${WORDS[j]}
    case $w in -c|--config-env) j=$((j+1)); w=${WORDS[j]-};; -c*) w=${w#-c};; --config-env=*) w=${w#*=};; *) continue;; esac
    case $w in [aA][lL][iI][aA][sS].*|[iI][nN][cC][lL][uU][dD][eE].*|[iI][nN][cC][lL][uU][dD][eE][iI][fF].*) MUT=1; UNRES=1; NOEX=1;; esac
  done
  case $SUB in
    commit|apply|am|checkout|switch|merge|rebase|reset|revert|clean|add|rm|mv|restore|cherry-pick|pull|submodule|filter-branch|update-ref|clone|init) mut=1;;
    # These write only where -o/--output points; that path alone is judged.
    archive|format-patch|diff|log|show) has_after "$si" -o '-o?*' --output '--output=*' '--output-directory*' && mut=1 out=1;;
    stash) case ${WORDS[si+1]-} in list|show) ;; *) mut=1;; esac;;
    worktree) case ${WORDS[si+1]-} in list|'') ;; *) mut=1;; esac;;
    push) for ((j=si+1; j<NW; j++)); do case ${WORDS[j]} in -*) ;; *) w=${WORDS[j]#file://}
            case $w in /*|.*|'~'*) MUT=1; each_base "$w" 0;; esac; break;; esac; done; return;;
  esac
  [ $mut = 1 ] || return 0; MUT=1
  for w in ${GENV[@]+"${GENV[@]}"}; do each_base "$w" 0; done
  for b in "${BASES[@]}"; do
    cur=$b; hadc=0
    for ((j=k+1; j<si; j++)); do w=${WORDS[j]}; v=""; [ $TOO_MANY = 1 ] && return
      case $w in
        -C|-C*) if [ "$w" = -C ]; then j=$((j+1)); v=${WORDS[j]-}; else v=${w#-C}; fi
          joinp "$cur" "$v"; cur=${JP%/.}; v=""; hadc=1
          [ ${#cur} -gt 1024 ] && { TOO_MANY=1; return; }; [ $out = 1 ] || add_path "$cur" / 0;;
        --work-tree=*|--git-dir=*) v=${w#*=};;
        --work-tree|--git-dir) j=$((j+1)); v=${WORDS[j]-};;
        -c) j=$((j+1)); case ${WORDS[j]-} in *.[wW][oO][rR][kK][tT][rR][eE][eE]=*) v=${WORDS[j]#*=};; esac;;
        -c*.[wW][oO][rR][kK][tT][rR][eE][eE]=*) v=${w#*=};;
        --config-env|--config-env=*) UNRES=1; [ "$w" = --config-env ] && j=$((j+1));;   # value comes from a variable
        --namespace|--exec-path|--super-prefix) j=$((j+1));;
      esac
      [ -n "$v" ] && { joinp "$cur" "$v"; add_path "$JP" / 0; }
    done
    if [ $out = 1 ]; then
      for ((j=si+1; j<NW; j++)); do w=${WORDS[j]}; v=""
        case $w in --output=*|--output-directory=*) v=${w#*=};; -o|--output|--output-directory) j=$((j+1)); v=${WORDS[j]-};; -o?*) v=${w#-o};; esac
        [ -n "$v" ] && add_path "$v" "$cur" 0
      done; continue
    fi
    { [ $hadc = 0 ] || [ "$MODE" = opaque ]; } && add_path . "$b" 0
    for ((j=si+1; j<NW; j++)); do pathy "${WORDS[j]}" && add_path "${WORDS[j]}" "$cur" 0; done
  done
}

judge_verb() {
  local k=$1 v=${WORDS[$1]##*/} cls=none des=0 j w any=0
  case $v in
    rm|rmdir|mv|chmod|chown|chgrp|unlink|shred|rsync|unzip|rimraf) cls=file des=1;;
    cp|touch|mkdir|ln|tee|dd|patch|truncate|install) cls=file;;
    sed|perl|ruby) has_after "$k" '-i*' '-[!-]*i*' '--in-place*' && cls=file;;
    gofmt) has_after "$k" '-w*' '-[!-]*w*' && cls=file;;
    tar) { has_after "$k" '-x*' '-[!-]*x*' '--extract' '--get' || case ${WORDS[k+1]-} in -*) false;; *x*) true;; *) false;; esac; } && cls=file des=1;;
    find) has_after "$k" '-delete' && cls=file des=1;;
    curl|wget) has_after "$k" '-o*' '-O*' '-P*' '--output*' '--remote-name*' '--output-document*' '--directory-prefix*' && cls=file;;
    git) git_verb "$k"; return;;
    npm|pnpm|yarn|bun) sub_after "$k"; case $SUB in install|i|ci|add|remove|rm|uninstall|un|update|up|upgrade|link|unlink|publish|init|dedupe|prune|import) cls=dir;; esac;;
    cargo) sub_after "$k"; case $SUB in add|remove|rm|update|fix|fmt|clean|init|new|vendor|publish|install|uninstall|generate-lockfile) cls=dir;; esac;;
    go) sub_after "$k"; case $SUB in generate|mod|get|work|fmt|fix|install|clean) cls=dir;; esac;;
    make|gmake) cls=dir; for ((j=k+1; j<NW; j++)); do case ${WORDS[j]} in
        --dry-run|--just-print|--recon|--question) cls=none;; --*|-*[!a-zA-Z]*) ;; -*[nq]*) cls=none;; esac; done;;
  esac
  # A verb read from a variable or $(...) could be anything.
  [ $cls = none ] && { case ${WORDS[k]} in *'$'*) MUT=1; NOEX=1; each_base . 0;; esac; return 0; }
  MUT=1
  for w in ${GENV[@]+"${GENV[@]}"}; do each_base "$w" 0; done
  if [ $cls = file ]; then
    # These act on a link itself, not through it (rm, mv, ln's names, chmod -h ...).
    case $v in rm|rmdir|unlink|mv|ln|find|rimraf) FOLLOW=0;;
      chmod|chown|chgrp) has_after "$k" '-h' '-[!-]*h*' && FOLLOW=0;; esac
    for ((j=k+1; j<NW; j++)); do w=${WORDS[j]}
      case $w in --*=*|[A-Za-z_]*=*) w=${w#*=};;
        -*) case $v$w in curl-o?*|wget-[OP]?*) w=${w#-?};; *) continue;; esac;; esac   # -o<path>
      any=1; each_base "$w" "$des"
    done
    case $v in ln) ln_rel "$k";; cp) cp_dest "$k";; esac
    FOLLOW=1
    [ $any = 1 ] && return 0
  fi
  each_base . 0
  for ((j=k+1; j<NW; j++)); do w=${WORDS[j]}
    case $w in
      -C|-D|-f|--file|--makefile|--directory|--prefix|--manifest-path|--cwd|--dir|--chdir) j=$((j+1)); each_base "${WORDS[j]-}" 0;;
      --file=*|--makefile=*|--directory=*|--prefix=*|--manifest-path=*|--cwd=*|--dir=*|--chdir=*) each_base "${w#*=}" 0;;
      -C?*) each_base "${w#-C}" 0;;
      -*) ;;
      *) pathy "$w" && each_base "$w" 0;;
    esac
  done
}

# dest_ops <k>: the operands of word k's command (OPS) and its destination (D: -t, else
# the last of two or more operands); OPS keeps the sources only (NS of them).
dest_ops() {
  local j w
  D=""; OPS=(); HARD=1
  for ((j=$1+1; j<NW; j++)); do w=${WORDS[j]}
    case $w in -t) j=$((j+1)); D=${WORDS[j]-};; -t?*) D=${w#-t};; --target-directory=*) D=${w#*=};;
      --symbolic) HARD=0;; --*) ;; -*s*) HARD=0;; -*) ;; *) OPS+=("$w");; esac
  done
  NS=${#OPS[@]}
  if [ -z "$D" ] && [ $NS -ge 2 ]; then NS=$((NS-1)); D=${OPS[NS]}; fi
}
# cp_dest <k>: cp into a directory writes <dir>/<source's name>, through a link of that
# name if one is there (cp out/lf K/ with K/lf -> ../M/f rewrites M/f). Each source's
# name is queued under the destination as a followed path; if the destination is a file
# the extra path only re-checks its dir. A source whose name is a glob queues the glob
# there, and one ending in / (its contents) queues <dest>/*: globbed, so the destination
# gets no opt-out.
# cp -R / -r / -a refuse to write through a link at the destination (macOS cp), so a
# recursive copy queues nothing more; mv and install replace the link.
cp_dest() {
  local j t
  for ((j=$1+1; j<NW; j++)); do case ${WORDS[j]} in --recursive|--archive|-[!-]*[Rra]*|-[Rra]) return 0;; esac; done
  dest_ops "$1"; [ -n "$D" ] || return 0
  FOLLOW=1
  for ((j=0; j<NS; j++)); do t=${OPS[j]}
    case $t in */) t='*';; *) t=${t##*/};; esac
    case $t in ''|.|..) t='*';; esac
    each_base "${D%/}/$t" 0
  done
}
# ln_rel <k>: a relative link target is read from the link's directory, not from the
# cwd: `cd out && ln -s ../M/f K/lf` points K/lf at M/f. Each target operand is also
# queued against the destination (the last operand, or -t) and against its parent, since
# either may be the link's directory. A hard link (no -s) is made to the file a source
# link points to (macOS ln follows it): each source is queued again as a followed path,
# so `ln K/lf W/h` with K/lf -> ../M/f is judged at M/f.
ln_rel() {
  local j t n
  dest_ops "$1"; n=$NS
  if [ $HARD = 1 ]; then
    FOLLOW=1; for ((j=0; j<n; j++)); do each_base "${OPS[j]}" 0; done
    return 0
  fi
  [ -n "$D" ] || return 0
  for ((j=0; j<n; j++)); do t=${OPS[j]}
    case $t in /*|'~'*) continue;; esac
    each_base "$D/$t" 0
    case $D in */*) each_base "${D%/*}/$t" 0;; esac
  done
}

# judge_seg: WORDS/REDS of one simple command, against every dir in BASES.
judge_seg() {
  local i=0 k wp=-1 r w pos
  NW=${#WORDS[@]}; FOLLOW=1
  for r in ${REDS[@]+"${REDS[@]}"}; do case $r in /dev/*) continue;; esac; MUT=1; each_base "$r" 0; done
  # GIT_* anywhere (VAR=, export, declare, env) counts for the rest of the command.
  # Config from the environment can define an alias: a writer to a place not followed.
  for w in ${WORDS[@]+"${WORDS[@]}"}; do case $w in GIT_CONFIG=*|GIT_CONFIG_[PCKVGS]*=*) MUT=1; UNRES=1; NOEX=1;; GIT_*=*) GENV+=("${w#*=}");; esac; done
  while [ $i -lt $NW ]; do w=${WORDS[i]}
    case $w in [A-Za-z_]*=*) case ${w%%=*} in *[!A-Za-z0-9_]*) break;; esac; i=$((i+1));; *) break;; esac
  done
  [ $i -lt $NW ] || return 0
  pos=("$i")
  for ((k=i; k<NW; k++)); do case ${WORDS[k]##*/} in
    command|builtin|nohup|nice|time|timeout|gtimeout|env|caffeinate|xcrun|stdbuf|arch|ionice|flock|setsid|script|npx|sudo|doas|exec|eval|xargs|parallel|watch|-exec|-execdir|-ok|-okdir|'!'|if|then|do|else|elif|while|until|'{') wp=$k; break;; esac; done
  if [ $wp -ge 0 ]; then for ((k=wp+1; k<NW; k++)); do case ${WORDS[k]} in -*|[A-Za-z_]*=*) ;; *) pos+=("$k");; esac; done; fi
  [ ${#pos[@]} -gt 64 ] && { TOO_MANY=1; return 0; }
  for k in "${pos[@]}"; do judge_verb "$k"; done
}

# ------------------------------------------------------------ structured mode

# scan: tokens of a command free of \ $ ` and <<. TYP: w word, r redirect target,
# o operator (newline counts as ;), x dropped (fd dup, input file). Fails on an
# unbalanced quote, a newline inside quotes, or a quoted leading ~.
scan() {
  local s=$1 n=${#1} i=0 c nx w="" inw=0 qc="" pend=""
  TOK=(); TYP=()
  flush() { if [ $inw = 1 ]; then TOK+=("$w"); case $pend in '') TYP+=(w);; r) TYP+=(r);;
      d) case $w in -|[0-9]|[0-9][0-9]|[0-9]-) TYP+=(x);; *) TYP+=(r);; esac;; *) TYP+=(x);; esac; pend=""; fi; w=""; inw=0; }
  while [ $i -lt $n ]; do
    c=${s:i:1}
    if [ -n "$qc" ]; then case $c in "$qc") qc="";; $'\n') return 1;; *) w+=$c;; esac; i=$((i+1)); continue; fi
    case $c in
      \'|\") [ $inw = 0 ] && [ "${s:i+1:1}" = '~' ] && return 1; qc=$c; inw=1;;
      ' '|$'\t') flush;;
      '#') if [ $inw = 0 ]; then while [ $i -lt $n ] && [ "${s:i:1}" != $'\n' ]; do i=$((i+1)); done; continue; fi; w+=$c;;
      '<'|'>') case $w in ''|*[!0-9]*) flush;; *) w=""; inw=0;; esac
        nx=${s:i+1:1}
        if [ "$c" = '>' ]; then case $nx in '>'|'|') i=$((i+1)); pend=r;; '&') i=$((i+1)); pend=d;; *) pend=r;; esac
        else case $nx in '>') i=$((i+1)); pend=r;; '&') i=$((i+1)); pend=x;; *) pend=x;; esac; fi;;
      '&') flush; nx=${s:i+1:1}
        case $nx in '&') i=$((i+1)); TOK+=('&&'); TYP+=(o);;
          '>') i=$((i+1)); [ "${s:i+1:1}" = '>' ] && i=$((i+1)); pend=r;;
          *) TOK+=('&'); TYP+=(o);; esac;;
      '|') flush; nx=${s:i+1:1}
        case $nx in '|') i=$((i+1)); TOK+=('||');; '&') i=$((i+1)); TOK+=('|');; *) TOK+=('|');; esac; TYP+=(o);;
      $'\n'|';') flush; pend=""; TOK+=(';'); TYP+=(o);;
      '('|')') flush; [ -n "$pend" ] && return 1   # > (a|b): a zsh glob as the target
        TOK+=("$c"); TYP+=(o);;
      *) w+=$c; inw=1;;
    esac
    i=$((i+1))
  done
  [ -z "$qc" ] || return 1
  flush
}

structured() {
  GENV=(); scan "$cmd" || return 1
  local nt=${#TOK[@]} a=0 b k st si=0 nseg op e s ops=() env=0 T
  b=$nt
  if [ $nt -gt 0 ] && [ "${TYP[0]}${TOK[0]}" = 'o(' ]; then
    [ "${TYP[nt-1]}${TOK[nt-1]}" = 'o)' ] || return 1; a=1; b=$((nt-1))
  fi
  SS=(); SE=(); SO=(); st=$a
  for ((k=a; k<b; k++)); do
    case ${TYP[k]}${TOK[k]} in
      'o('|'o)') return 1;;
      o*) SS+=("$st"); SE+=("$k"); SO+=("${TOK[k]}"); st=$((k+1)); env=0;;
      wenv) env=1;;
      w-C|w-C*|w--chdir*) [ $env = 1 ] && return 1;;
      weval|wexec|wsource|wsh|wbash|wzsh|wdash|wksh|wfish|wsu|wsudo|wdoas|wxargs|wparallel|wwatch|wpushd|wpopd|w-exec|w-execdir|w-ok|w-okdir) return 1;;
      w-S*|w--split-string*) [ $env = 1 ] && return 1;;
    esac
  done
  SS+=("$st"); SE+=("$b"); SO+=(""); nseg=${#SS[@]}
  while [ $si -lt $nseg ]; do
    s=${SS[si]}; e=${SE[si]}
    [ $s -lt $e ] && [ "${TYP[s]}${TOK[s]}" = wcd ] || break
    [ $((e-s)) = 2 ] && [ "${TYP[s+1]}" = w ] || return 1
    op=${TOK[s+1]}
    case $op in ''|-*|*[*?[{]*) return 1;; esac
    case ${SO[si]} in '&&'|';'|'') ;; *) return 1;; esac
    ops+=("$op"); si=$((si+1))
  done
  for ((k=${SS[si]:-$b}; k<b; k++)); do
    case ${TYP[k]}${TOK[k]} in wcd|wchdir) return 1;; 'o||') [ ${#ops[@]} -gt 0 ] && return 1;; esac
  done
  for ((k=si; k<nseg; k++)); do s=${SS[k]}; [ "${TYP[s]-}${TOK[s]-}" = "w." ] && return 1; done
  T=$pdir
  if [ ${#ops[@]} -gt 0 ]; then
    T=$(cd -P -- "$pdir" || exit 1
      for op in "${ops[@]}"; do joinp "$PWD" "$op"; cd -P -- "$JP" 2>/dev/null || exit 1; done
      printf '%s' "$PWD") || return 1
  fi
  BASES=("$T")
  for ((; si<nseg; si++)); do
    WORDS=(); REDS=()
    for ((k=SS[si]; k<SE[si]; k++)); do case ${TYP[k]} in w) WORDS+=("${TOK[k]}");; r) REDS+=("${TOK[k]}");; esac; done
    judge_seg
  done
  return 0
}

# ------------------------------------------------------------ opaque mode

opaque() {
  MODE=opaque; PS=(); PD=(); PF=(); PX=(); UNRES=0; MUT=0; GENV=()
  local norm line k t b r i new=0 CDT=() SEGS=()
  # Read the command both with backslash-newline joined and as written, quotes and
  # backslashes dropped: whichever reading the shell uses is covered.
  norm=$(printf '%s' "$cmd" | sed -e ':a' -e '/\\$/{' -e 'N' -e 's/\\\n//' -e 'ba' -e '}' | tr -d "\\\\\"'"
         printf '\n'; printf '%s' "$cmd" | tr -d "\\\\\"'")
  REDS=()
  while IFS= read -r r; do [ -n "$r" ] && REDS+=("$r"); done < <(printf '%s\n' "$norm" | sed -E 's/[0-9]*[<>]&[0-9-]+//g' \
    | grep -oE '[0-9]*>>?[|&]?[[:space:]]*[^[:space:];&|()<>]+' | sed -E 's/^[0-9]*>>?[|&]?[[:space:]]*//')
  # > (lf|x) is a zsh glob in the cwd that the pattern above drops: queue * in its place.
  local re_rp='>[[:space:]]*\('
  [[ $norm =~ $re_rp ]] && REDS+=('*')
  # Redirect targets stop at an operator, so `>/dev/null; rm x` keeps its rm.
  while IFS= read -r line; do case $line in *[![:space:]]*) SEGS+=("$line");; esac; done < <(printf '%s\n' "$norm" \
    | sed -E 's/[0-9]*(>>?|<<?|<)[|&]?[[:space:]]*[^[:space:];&|()<>]*//g' | tr ';|&(){}`' '\n\n\n\n\n\n\n\n')
  BASES=("$pdir")
  for line in ${SEGS[@]+"${SEGS[@]}"}; do
    WORDS=($line)
    for ((k=0; k<${#WORDS[@]}; k++)); do
      case ${WORDS[k]} in popd) UNRES=1;; cd|pushd|chdir) ;; *) continue;; esac
      t=$HOME
      for ((i=k+1; i<${#WORDS[@]}; i++)); do case ${WORDS[i]} in -P|-L|-e|-@|--) ;; *) t=${WORDS[i]}; break;; esac; done
      case $t in -*|+*|*'$'*|*'`'*|*[*?[{]*|'~'[!/]*) UNRES=1; continue;; esac
      for r in ${CDT[@]+"${CDT[@]}"}; do [ "$r" = "$t" ] && continue 2; done
      CDT+=("$t"); [ ${#CDT[@]} -gt 16 ] && UNRES=1
    done
  done
  for ((i=0; i<4 && ${#CDT[@]} > 0; i++)); do
    new=0
    while IFS= read -r t; do
      for b in "${BASES[@]}"; do [ "$b" = "$t" ] && continue 2; done
      BASES+=("$t"); new=1
    done < <(for b in "${BASES[@]}"; do for t in "${CDT[@]}"; do
        joinp "$b" "$t"; cd -P -- "$JP" 2>/dev/null && printf '%s\n' "$PWD"; done; done | sort -u)
    [ ${#BASES[@]} -gt 16 ] && { UNRES=1; break; }
    [ $new = 1 ] || break
  done
  [ $new = 1 ] && [ $i = 4 ] && UNRES=1
  for line in ${SEGS[@]+"${SEGS[@]}"}; do WORDS=($line); judge_seg; REDS=(); done
  # A mutation hides behind words this mode cannot follow, so every path word counts.
  if [ $MUT = 1 ]; then
    for line in ${SEGS[@]+"${SEGS[@]}"}; do WORDS=($line)
      [ $TOO_MANY = 1 ] && break; for t in ${WORDS[@]+"${WORDS[@]}"}; do case $t in *'$'*|*'`'*) pathy "${t#*\$}" && UNRES=1;; *) pathy "$t" && each_base "$t" 1;; esac; done
    done
  fi
}

# ------------------------------------------------------------ quoted heredocs

# A quoted heredoc's body (<<'D' <<"D" <<\D, also <<-) is data, but the readings above
# take its lines for commands: `- a / b` reads as a destructive op on /. strip_heredocs
# drops the bodies, only when the whole command is one of the shapes below; on anything
# else cmd stays as written and the old reading applies. Shapes, each after an optional
# literal `cd PATH &&` chain:  cat >|>> LIT <<'D' (redirect before or after),
# tee [-a] LIT... <<'D' [>/dev/null],  gh pr|issue|release|api ... "$(cat <<'D' ... D )".
# Between and after them only ; / && pieces of gh, cat, echo, printf, ls, wc, head,
# tail, diff, true, rm, mkdir, cd, which are then judged as usual.
HD_L='[A-Za-z0-9_./~+,:@%][A-Za-z0-9_./~+,:@%=-]*'
HD_CD="^cd[ ]+$HD_L[ ]*&&[ ]*(.*)$"
HD_RA="^cat[ ]+(>>?[ ]*$HD_L[ ]+<<|<<[ ]+>>?[ ]*$HD_L)[ ]*$"
HD_RB="^tee([ ]+-a)?([ ]+$HD_L)+[ ]+<<([ ]+>/dev/null)?[ ]*$"
HD_RC='^gh[ ]+(pr|issue|release|api)([ ].*)?[ ]"\$\(cat[ ]+<<$'
HD_GC='"$(cat'   # in a variable: bash 3.2 cannot parse it inside ${x%...}

# hd_scan <text>: fails on what the tail check cannot read (a backslash outside single
# quotes, $' ${ $( `, # | ( ) or a lone & outside quotes, <<, a quote across lines).
# HU gets the text with quoted chars as x and ; && newline as separate words.
hd_scan() {
  local s=$1 n=${#1} i=0 c nx pv="" q="" u=""
  while [ $i -lt $n ]; do
    c=${s:i:1}; nx=${s:i+1:1}
    if [ "$q" = "'" ]; then
      case $c in "'") q="";; $'\n') return 1;; esac; u+=x
    else
      case $c in '\'|'`'|$'\r') return 1;; '$') case $nx in "'"|'{'|'(') return 1;; esac;; esac
      if [ "$q" = '"' ]; then
        case $c in '"') q="";; $'\n') return 1;; esac; u+=x
      else
        case $c in
          "'"|'"') q=$c; u+=x;;
          '#'|'|'|'('|')') return 1;;
          '&') if [ "$nx" = '&' ]; then i=$((i+1)); u+=' && '
               elif [ "$pv" = '>' ] || [ "$nx" = '>' ]; then u+=$c; else return 1; fi;;
          ';'|$'\n') u+=' ; ';;
          '<') [ "$nx" = '<' ] && return 1; u+=$c;;
          *) u+=$c;;
        esac
      fi
    fi
    pv=$c; i=$((i+1))
  done
  [ -z "$q" ] || return 1
  HU=$u
}

strip_heredocs() {
  local IFS=$'\n' ln=() n i=0 h x w tok d dash kind pre post l lits=() out="" tl="" tll=0 first=1 bp bo e=1 g=0 p=0
  ln=($cmd); n=${#ln[@]}
  while [ $i -lt $n ]; do
    h=${ln[i]}; i=$((i+1))
    case $h in *'~'[-+0-9]*) return 0;; esac   # ~- ~+ ~N (OLDPWD, PWD, dir stack) are not followed
    case $h in *'<<'*) ;; *)   # a tail line
      [ $first = 1 ] && return 0
      out+=$h$'\n'; tl+=$h$'\n'; tll=$((tll+1))
      { [ ${#tl} -gt 1024 ] || [ $tll -gt 200 ]; } && return 0
      continue;; esac
    [ ${#h} -le 1024 ] || return 0
    case $h in *'<<'*'<<'*) return 0;; esac
    pre=${h%%<<*}; tok=${h#*<<}; post=""
    case $tok in *' '*) post=" ${tok#* }"; tok=${tok%% *};; esac
    dash=0; case $tok in -*) dash=1; tok=${tok#-};; esac
    case $tok in \'*\') d=${tok#\'}; d=${d%\'};; \"*\") d=${tok#\"}; d=${d%\"};; \\*) d=${tok#\\};; *) return 0;; esac
    case $d in ''|[0-9]*|*[!A-Za-z0-9_]*) return 0;; esac
    x=$pre'<<'$post
    while [[ $x =~ $HD_CD ]]; do x=${BASH_REMATCH[1]}; done
    IFS=' '
    if [[ $x =~ $HD_RA ]]; then
      kind=a; w=${x#cat}; w=${w/<</ }; w=${w//>/ }; set -- $w; lits+=("$1")
    elif [[ $x =~ $HD_RB ]]; then
      kind=b; w=${x#tee}; w=${w%%<<*}; set -- $w; for w; do [ "$w" = -a ] || lits+=("$w"); done
    elif [[ $x =~ $HD_RC ]]; then
      kind=c; hd_scan "${x%"$HD_GC"*}" || return 0
      case " $HU " in *' ; '*|*' && '*) return 0;; esac
    else return 0; fi
    IFS=$'\n'
    out+=$pre$post$'\n'; first=0; bp=0; bo=0
    while :; do   # the body, up to a line that is exactly the delimiter
      [ $i -lt $n ] || return 0
      l=${ln[i]}; i=$((i+1))
      [ $dash = 1 ] && while :; do case $l in $'\t'*) l=${l#?};; *) break;; esac; done
      [ "$l" = "$d" ] && break
      case $l in "$d"*) return 0;; esac
      if [ $kind = c ]; then case $l in *')'*) bp=1;; esac; case $l in *[\"\$\`\\]*) bo=1;; esac; fi
    done
    # Bash 3.2 ends "$( at a )" it meets in the body, so such a body is not read as data.
    [ $kind = c ] || continue
    { [ $bp = 1 ] && [ $bo = 1 ]; } && return 0
    [ $i -lt $n ] || return 0
    l=${ln[i]}; i=$((i+1))
    case $l in ')"'*) ;; *) return 0;; esac
    case $l in *'~'[-+0-9]*) return 0;; esac
    out+=$l$'\n'; tl+="gh pr ${l#')"'}"$'\n'; tll=$((tll+1))
    { [ ${#tl} -gt 1024 ] || [ $tll -gt 200 ]; } && return 0
  done
  [ $first = 0 ] || return 0
  hd_scan "$tl" || return 0
  IFS=$' \t\n'; set -- $HU   # set -f is on: no globbing
  for w; do
    if [ $g = 1 ]; then case $w in pr|issue|release|api) g=0; continue;; *) return 0;; esac; fi
    if [ $e = 1 ]; then
      case $w in gh) g=1;; cat|echo|printf|ls|wc|head|tail|diff|true|rm|mkdir|cd) ;; *) return 0;; esac
      for x in ${lits[@]+"${lits[@]}"}; do [ "$w" = "$x" ] && return 0; done
      e=0; p=$((p+1)); [ $p -gt 200 ] && return 0
    else case $w in ';'|'&&') e=1;; esac; fi
  done
  [ $g = 0 ] || return 0
  cmd=${out%$'\n'}
}

# ------------------------------------------------------------ guard

# Creating or naming an opt-out file in a writer is the user's alone, whoever asks and from
# wherever; other removals pass and only fail safe (header). (Coarse
# on Bash: any command naming one with a writing word, e.g. git log -- .claude/no-isolation.)
# Matched in lower case: APFS finds .claude/NO-ISOLATION when asked for the marker.
if [ "$tool" = Bash ]; then
  case $(printf '%s' "$cmd_raw" | tr -d "\\\\\"'" | tr '[:upper:]' '[:lower:]') in *no-isolation*) mut_ev "$cmd_raw" && deny "$SELF";; esac
else
  lexnorm "$ap"; case $(printf '%s' "$LEX" | tr '[:upper:]' '[:lower:]') in */.claude/no-isolation|*/hooks/no-isolation-repos) deny "$SELF";; esac
fi
# has_marker <top>: .claude is a real directory there and the marker a regular file, neither
# a symlink, so a marker cannot be switched on by writing a file outside the repo. The entry
# must be named no-isolation byte for byte: APFS finds NO-ISOLATION, or no-iſolation (U+017F
# folds to s), when asked for the marker, and SELF does not see the latter. The bracket makes
# the shell read the directory and match the stored name byte for byte (C locale); the
# quoted top is taken literally.
has_marker() {
  [ -d "$1/.claude" ] && [ ! -L "$1/.claude" ] && [ -f "$1/.claude/no-isolation" ] && [ ! -L "$1/.claude/no-isolation" ] || return 1
  local t="$1/.claude/no-isolation"
  set +f; set -- "$1"/.claude/no-isolatio[n]; set -f
  [ $# = 1 ] && [ "$1" = "$t" ]
}
# main_of: after info, MT is the main checkout's top when one can be found: the dir's own
# for a main checkout; for a linked worktree, the parent of the common dir only when that
# is <top>/.git. A bare repo, or one whose git dir lives apart (--separate-git-dir), has no
# main top a worktree can find (git keeps no pointer back), so MT stays empty there --
# unless that git dir is itself named .git (a bare repo at proj/.git, a separate one at
# sep/foo/.git): then MT is proj or sep/foo, and a marker there counts. Only the user, or a
# writer the hook does not follow, can place one there (SELF refuses naming it).
main_of() { MT=""; if [ "$IM" = 1 ]; then MT=$IMT; else case $IMC in */.git) MT=${IMC%/.git};; esac; fi; }

dir=$cwd
# Edit/Write through a symlink to a file writes the link's target: its dir is the one that
# counts (the resolve below follows the link too).
if [ -n "$path" ]; then
  fp=$ap
  if [ -L "$fp" ] && [ ! -d "$fp" ]; then
    fp=$(/usr/bin/readlink -f -- "$ap" 2>/dev/null)
    case $fp in /*) ;; *) [ -n "$agent" ] && deny "$R2U"; deny "$R1";; esac
  fi
  dir=$(dirname "$fp")
fi
if [ ! -d "$dir" ]; then   # new dirs: the nearest existing parent, read lexically, if in a repo
  lexnorm "$dir"; dir=$LEX; while [ ! -d "$dir" ]; do dir=${dir%/*}; dir=${dir:-/}; done
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || dir=$cwd
fi

# Outside any work tree only a path into a main checkout is refused (Bash only).
INREPO=1; git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { [ "$tool" = Bash ] || allow; INREPO=0; }
top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
# The marker counts at the main checkout's top only (main_of). One that exists in a
# worktree alone opts nothing out: else an agent could copy a marker there (tar, cp -r of
# a marked root) and free its own cwd.
if [ -n "$top" ]; then info "$dir"; main_of; [ -n "$MT" ] && has_marker "$MT" && allow; fi

# Global opt-out list, kept outside any repo so it needs no in-repo marker file.
# A line may carry an expiry — "<path> until YYYY-MM-DD" — and stops matching
# after that day, so a temporary exemption reverts to guarded on its own.
# EX holds the live entries, compared as written (after ~ expansion) with a main
# checkout's top: here the cwd's, and in the resolve loop each target's (ex_main).
exempt=~/.claude/hooks/no-isolation-repos
EX=()
if [ -f "$exempt" ]; then
  today=$(date +%F)
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    case "$line" in
      *' until '*)
        [[ $today > ${line##* until } ]] && continue
        line=${line%% until *};;
    esac
    line=${line%/}
    eval "line=$line" 2>/dev/null
    [ -n "$line" ] && EX+=("$line")
  done < "$exempt"
fi
if [ -n "$top" ] && [ ${#EX[@]} -gt 0 ]; then
  common_root=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  main_top=${common_root%/.git}
  for line in "${EX[@]}"; do [ "$line" = "$top" ] || [ "$line" = "$main_top" ] && allow; done
fi
is_listed() { local e; for e in ${EX[@]+"${EX[@]}"}; do [ "$e" = "$1" ] && return 0; done; return 1; }
# is_exempt <main top>: listed, or the .claude/no-isolation marker at its top (has_marker).
# Only a main checkout's top counts, here as for the cwd above; paths into a linked
# worktree are judged as before. Cached per top; XMK is set when the marker is there
# (is_marked).
XK=(); XV=(); XM=(); XMK=0
is_exempt() {
  local i v=1 m=0
  XMK=0; [ -n "$1" ] || return 1
  for ((i=0; i<${#XK[@]}; i++)); do [ "${XK[i]}" = "$1" ] && { XMK=${XM[i]}; return "${XV[i]}"; }; done
  has_marker "$1" && m=1
  if [ $m = 1 ] || is_listed "$1"; then v=0; fi
  XK+=("$1"); XV+=("$v"); XM+=("$m"); XMK=$m; return $v
}
is_marked() { is_exempt "$1"; [ $XMK = 1 ]; }

pdir=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || pdir=$dir

if [ "$tool" = "Bash" ]; then
  # Cap first, before anything that grows faster than the input.
  if [ ${#cmd_raw} -gt 16384 ]; then mut_ev "$cmd_raw" && deny "$LONG"; allow; fi
  case $cmd in *'<<'*) strip_heredocs;; esac   # bodies of allowlisted quoted heredocs
  # zsh patterns the lexer splits at ( | < >: K/l(f|x), K/(a|b), K/l<->, K/l<1-9>. A ( glued
  # to a word (not $( <( >( =() or <N-M> anywhere bars the opt-out for every path (NXC).
  # So does a ( that opens a word after a redirect (> (lf|x), >(...) too) or after another
  # word (tee (lf|x)); bash rejects both, zsh globs them.
  re_nx='[^[:space:];&|$<>=(]\(|<[0-9]*-[0-9]*>|>[[:space:]]*\(|[^[:space:];&|<>(][[:space:]]+\('
  [[ $cmd =~ $re_nx ]] && NXC=1
  MODE=structured; MUT=0; NOEX=0
  case $cmd in *[\\\$\`]*|*'<<'*) opaque;; *) structured || opaque;; esac
else
  # Rule 2: the nearest existing parent of file_path, as written and normalized (batch_resolve).
  PS=("${ap:-$pdir}"); PD=(0); PF=(1); PX=(0); MUT=1; UNRES=0
fi

# A write through a symlink to a file lands at its target, which may sit in a guarded
# checkout (a link made earlier, or brought in by tar -x, mv, cp -R, git checkout, an
# unlisted writer). Each such link a writer goes through (PF=1: not rm, mv, ln's names,
# chmod -h) is collected, and all of them are resolved by one readlink -f, which follows
# the chain as far as the kernel does (and further) and resolves a dangling last hop to
# the path a write would create. A directory symlink is already followed by cd -P. Over
# 256 distinct links: !LONG. An answer that does not map one line per link, or that is
# still a link (a loop, a chain longer than readlink follows): !UNRES. Each line carries
# PX: 1 bars the opt-out for that path.
batch_resolve() {
  local i p d self LK=() n r IFS=$'\n'
  for ((i=0; i<${#PS[@]}; i++)); do
    LEX=""
    case ${PS[i]} in */.|*/./*|*/..|*/../*) lexnorm "${PS[i]}";; esac
    for p in "${PS[i]}" ${LEX:+"$LEX"}; do
      while [ ${#p} -gt 1 ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
      d=$p; self=1
      until cd -P -- "$d" 2>/dev/null; do self=0; d=${d%/*}; [ -n "$d" ] || d=/; done
      printf '%s\t%s\t%s\t%s\n' "$PWD" "$self" "${PD[i]}" "${PX[i]}"
      [ $self = 0 ] && [ "${PF[i]}" = 1 ] && [ -L "$p" ] && LK+=("$p")
    done
  done
  [ ${#LK[@]} -gt 0 ] || return 0
  for p in "${LK[@]}"; do case $p in *$'\n'*) printf '!UNRES\n'; return;; esac; done
  LK=($(printf '%s\n' "${LK[@]}" | sort -u))   # IFS is a newline here
  n=${#LK[@]}
  [ $n -gt 256 ] && { printf '!LONG\n'; return; }
  r=$(/usr/bin/readlink -f -- "${LK[@]}" 2>/dev/null)
  LK=($r)
  [ ${#LK[@]} = $n ] || { printf '!UNRES\n'; return; }
  for p in "${LK[@]}"; do
    case $p in /*) ;; *) printf '!UNRES\n'; continue;; esac
    [ -L "$p" ] && { printf '!UNRES\n'; continue; }
    d=$p; self=1
    until cd -P -- "$d" 2>/dev/null; do self=0; d=${d%/*}; [ -n "$d" ] || d=/; done
    printf '%s\t%s\t0\t0\n' "$PWD" "$self"   # removing a link leaves its target: des 0
  done
}
# ------------------------------------------- rule 1 exactly as the original judged it
# No agent: the original per-segment filter, paths relative to the cwd, cd ignored.
# Same verdicts, without its per-word forks: dirs resolved once (cached, at most 200),
# redirect targets and words extracted in one sed pass, flags matched with [[ =~ ]].
OK=(); OV=()
o_in() {
  local p=$1 d b i
  p=${p#[\"\']}; p=${p%[\"\']}
  case $p in '~') p=$HOME;; '~/'*) p=$HOME/${p#'~/'};; esac
  case $p in /*) ;; *) p=$pdir/$p;; esac
  b=${p##*/}; d=${p%/*}; [ -n "$d" ] || d=/
  for ((i=0; i<${#OK[@]}; i++)); do [ "${OK[i]}" = "$d" ] && break; done
  if [ $i = ${#OK[@]} ]; then
    [ $i -ge 200 ] && { TOO_MANY=1; return 1; }
    OK+=("$d"); OV+=("$(cd "$d" 2>/dev/null && pwd -P || printf '%s' "${p%/*}")")
  fi
  p=${OV[i]%/}/$b
  case $p in "$top"|"$top"/*) return 0;; esac
  return 1
}
o_flag() { local re="(^|[[:space:]])$2([[:space:]=]|$)"; [[ $1 =~ $re ]]; }
o_sub() {  # first real argument after word $1 in OWS
  local w hit=0 skip=0
  OSUB=""
  for w in "${OWS[@]}"; do
    if [ $hit = 0 ]; then [ "${w##*/}" = "$1" ] && hit=1; continue; fi
    if [ $skip = 1 ]; then skip=0; continue; fi
    case $w in
      -C|-c|-f|-j|-e|-p|-P|--file|--git-dir|--work-tree|--manifest-path|--exec-path) skip=1;;
      -*) ;;
      *) OSUB=$w; return;;
    esac
  done
}
o_args() {  # some path-shaped argument lands in the repo, or there is none
  local w seen=0 i
  for ((i=OIDX+1; i<${#OWS[@]}; i++)); do w=${OWS[i]}
    case $w in -*) continue;; esac
    seen=1; o_in "$w" && return 0
  done
  [ $seen = 0 ]
}
o_seg() {
  local seg=$1 w i=0 xre='(-execdir|-exec|xargs)[[:space:]]+(sudo[[:space:]]+)?[A-Za-z0-9_./-]*/?(mv|rm|cp|ln|chmod|chown|touch|mkdir|sed|perl|tee|dd|truncate|shred|git)([[:space:]]|$)'
  OCMD=""; OIDX=0
  for w in ${OWS[@]+"${OWS[@]}"}; do
    case $w in
      *=*|sudo|env|command|nohup|time|exec|builtin|then|do|else|'!'|-*) i=$((i+1));;
      *) OCMD=${w##*/}; OCMD=${OCMD#[\"\']}; OIDX=$i; break;;
    esac
  done
  [ -n "$OCMD" ] || return 1
  [[ $seg =~ $xre ]] && o_args && return 0
  case $OCMD in
    mv|rm|cp|rsync|touch|mkdir|rmdir|ln|unlink|chmod|chown|tee|dd|patch|truncate|shred|install) o_args;;
    sed|perl|ruby) { o_flag "$seg" '-[a-zA-Z]*i' || o_flag "$seg" '--in-place'; } && o_args;;
    gofmt) o_flag "$seg" '-[a-zA-Z]*w' && o_args;;
    git) o_sub git
      case $OSUB in
        commit|apply|am|checkout|switch|merge|rebase|reset|revert|clean|add|rm|mv|restore|cherry-pick|pull|submodule|filter-branch) return 0;;
        stash) o_sub stash; case $OSUB in list|show|'') return 1;; *) return 0;; esac;;
        *) return 1;;
      esac;;
    npm|pnpm|yarn|bun) o_sub "$OCMD"
      case $OSUB in install|i|ci|add|remove|rm|uninstall|un|update|up|upgrade|link|unlink|publish|init|dedupe|prune|import) return 0;; *) return 1;; esac;;
    cargo) o_sub cargo
      case $OSUB in add|remove|rm|update|fix|fmt|clean|init|new|vendor|publish|install|uninstall|generate-lockfile) return 0;; *) return 1;; esac;;
    go) o_sub go
      case $OSUB in generate|mod|get|work|fmt|fix|install|clean) return 0;; *) return 1;; esac;;
    make|gmake) o_flag "$seg" '-[a-zA-Z]*[nq]' && return 1; return 0;;
    *) return 1;;
  esac
}
orig_r1() {
  local t seg segs=() ws=() i
  [ "$tool" = Bash ] && [ $INREPO = 1 ] || return 1
  # Redirect targets that are real files inside the repository (quoted spans dropped).
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case $t in /dev/*) continue;; esac
    o_in "$t" && return 0
  done < <(printf '%s\n' "$cmd" | tr ';|&(){}`' '\n\n\n\n\n\n\n\n' \
    | sed -E -e "s/'[^']*'//g" -e 's/"[^"]*"//g' \
    | sed -E 's/[0-9]*>>?&[0-9-]+//g' \
    | grep -oE '[0-9]*>>?[|]?[[:space:]]*[^[:space:];&|)]+' \
    | sed -E 's/^[0-9]*>>?[|]?[[:space:]]*//')
  while IFS= read -r seg; do segs+=("$seg"); done < <(printf '%s\n' "$cmd" | tr ';|&(){}`' '\n\n\n\n\n\n\n\n')
  while IFS= read -r seg; do ws+=("$seg"); done < <(printf '%s\n' "$cmd" | tr ';|&(){}`' '\n\n\n\n\n\n\n\n' \
    | sed -E 's/[0-9]*(>>?|<<?)[|]?[[:space:]]*[^[:space:]]*//g')
  for ((i=0; i<${#segs[@]}; i++)); do
    case ${segs[i]} in *[![:space:]]*) ;; *) continue;; esac
    read -ra OWS <<<"${ws[i]-}"
    o_seg "${segs[i]}" && return 0
    [ $TOO_MANY = 1 ] && return 1
  done
  return 1
}

# Resolve every queued path in one subshell: the nearest existing directory (physical),
# for the path as written and lexically normalized, and whether the path itself exists.
# MAINS: the main checkout top of the cwd and of each base, for the parent-removal rule;
# MOK: that top as main_of finds it (empty for a bare or separate-git-dir worktree), the
# only one the opt-out may clear.
info "$pdir"; CWD_C=$IMC; MAINS=("$IMT"); main_of; MOK=("$MT")
for b in ${BASES[@]+"${BASES[@]}"}; do info "$b"; MAINS+=("$IMT"); main_of; MOK+=("$MT"); done
HOMEP=$(cd -P -- "$HOME" 2>/dev/null && pwd -P) || HOMEP=$HOME
# ex_main <main top>: it is opted out, and so is every main checkout that holds it (a write
# into a repo nested in M changes M's checkout). The walk stops at a linked worktree or
# outside any repo. A lookup over the 64-dir cap counts as not exempt.
ex_main() {
  local t=$1 p
  while is_exempt "$t"; do
    p=${t%/*}; p=${p:-/}
    [ "$p" = "$t" ] && return 0
    info "$p"; [ $TOO_MANY = 1 ] && return 1
    [ "$IM" = 1 ] || return 0
    t=$IMT
  done
  return 1
}
# can_ex <main top>: the opt-out may clear a path into it. The word scan behind NOEX,
# coarse on purpose (clean or submodule anywhere, in either reading with quotes and
# backslashes dropped, so -m "clean up" counts), runs once, before the first path is
# cleared: only commands that touch an opted-out main checkout pay for it.
SCANNED=0
can_ex() {
  [ "${NOEX-0}" = 0 ] && is_exempt "$1" || return 1
  if [ $SCANNED = 0 ] && [ "$tool" = Bash ]; then
    SCANNED=1
    { printf '%s' "$cmd" | sed -e ':a' -e '/\\$/{' -e 'N' -e 's/\\\n//' -e 'ba' -e '}'; printf '\n'; printf '%s' "$cmd"; } \
      | tr -d "\\\\\"'" | grep -E '(^|[^[:alnum:]_])(clean|submodule)([^[:alnum:]_]|$)' >/dev/null && NOEX=1
  fi
  [ "${NOEX-0}" = 0 ]
}
HIT=0; R1HIT=0; EXU=0   # EXU: the opt-out cleared a path that would have hit
MKHIT=0; LNKU=0
if [ ${#PS[@]} -gt 0 ] && [ $TOO_MANY = 0 ]; then
  while IFS=$'\t' read -r L self des nx; do
    [ -n "$L" ] || continue
    case $L in '!LONG') TOO_MANY=1; break;; '!UNRES') LNKU=1; continue;; esac
    info "$L"; [ $TOO_MANY = 1 ] && break
    # The .claude dir holding a main checkout's marker is the user's too: any writer naming
    # it (rm -rf, mv away and back, cp -r it elsewhere) is refused as SELF. Files under it
    # are judged as usual. -ef and the case pattern: APFS ignores case, PWD keeps it.
    [ "$self" = 1 ] && [ "$IM" = 1 ] && case ${L##*/} in [.][cC][lL][aA][uU][dD][eE])
      [ "${L%/*}" -ef "$IMT" ] && is_marked "$IMT" && MKHIT=1;; esac
    # A path into an opted-out main checkout is judged as one outside any repo, except
    # that removing the checkout itself is still refused (below, and via MAINS). A globbed
    # path (nx=1) gets no opt-out: it is judged as if neither the list nor the marker held.
    et=""; [ "$nx" != 1 ] && [ "$IM" = 1 ] && can_ex "$IMT" && et=$IMT
    if [ -n "$et" ] && ex_main "$et"; then
      EXU=1
      # Only the structured reading knows the verb on L is destructive; the opaque one
      # marks every path word so, cd and -C operands too.
      [ "$des" = 1 ] && [ "$self" = 1 ] && [ "$L" -ef "$et" ] && [ "${MODE-}" = structured ] && HIT=1
    else
      [ $TOO_MANY = 1 ] && break
      [ -n "$et" ] && info "$L"   # ex_main moved IM/IMT/IMC to a parent
      [ "$IM" = 1 ] && HIT=1
      { [ -n "$IMC" ] && [ "$IMC" = "$CWD_C" ]; } && R1HIT=1
      [ -n "$top" ] && case $L/ in "$top"/*) R1HIT=1;; esac
    fi
    if [ "$des" = 1 ] && [ "$self" = 1 ]; then
      [ "$L" = / ] || [ "$L" = "$HOMEP" ] && HIT=1
      for ((j=0; j<${#MAINS[@]}; j++)); do m=${MAINS[j]}; [ -n "$m" ] && case $m/ in "$L"/*)   # an opted-out m itself: above
        [ "$nx" != 1 ] && [ "$L" = "$m" ] && [ "${MOK[j]}" = "$m" ] && can_ex "$m" && { EXU=1; continue; }; HIT=1;; esac; done
    fi
  done < <(batch_resolve | sort -u)
fi

[ $MKHIT = 1 ] && deny "$SELF"
# A link a writer goes through whose target could not be read: fail closed.
[ $LNKU = 1 ] && { [ -n "$agent" ] && deny "$R2U"; deny "$R1"; }
[ $TOO_MANY = 1 ] && deny "$LONG"
if [ $INREPO = 0 ]; then
  [ $HIT = 1 ] && { [ -n "$agent" ] && deny "$R2"; deny "$R1"; }
  # Out of any repo an unresolved target is let through, unless the opt-out cleared a path:
  # the variable could name the main checkout the opted-out one sits beside.
  [ $EXU = 1 ] && [ $MUT = 1 ] && [ $UNRES = 1 ] && { [ -n "$agent" ] && deny "$R2U"; deny "$R1"; }
  allow
fi
if [ -z "$agent" ]; then
  [ "$tool" = Bash ] || deny "$R1"
  { [ $HIT = 1 ] || [ $R1HIT = 1 ] || { [ $MUT = 1 ] && [ $UNRES = 1 ]; }; } && deny "$R1"
  orig_r1 && deny "$R1"
  [ $TOO_MANY = 1 ] && deny "$LONG"
  allow
fi
[ $HIT = 1 ] && deny "$R2"
[ $MUT = 1 ] && [ $UNRES = 1 ] && deny "$R2U"
allow
