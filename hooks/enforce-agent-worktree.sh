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
# Opt out: ~/.claude/hooks/no-isolation-repos ("<path> [until YYYY-MM-DD]"), .claude/no-isolation,
# CLAUDE_ENFORCE_OFF=1 -- judged on the cwd / file dir only; only the user may edit the markers.
# Not caught: symlinks made beforehand, writers not listed (gzip, sort -o, ditto, python -c).
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
LONG="コマンドが長すぎて判定できません（16384 文字・64 ディレクトリ・2000 パス・1 コマンド 64 語位置のいずれかを超えた）。分割してください。"
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
# back to the directory it expands in; what cannot be read literally sets UNRES.
PS=(); PD=(); UNRES=0; GENV=()
add_path() {
  local w=$1
  [ ${#PS[@]} -ge 2000 ] && { TOO_MANY=1; return; }
  case $w in ''|'{}'|*://*) return;; *'$'*|*'`'*|'~'[!/]*|*'{'*,*'}'*|*'{'*..*'}'*) UNRES=1; return;; esac
  case $w in *[*?[{]*) w=${w%%[*?[{]*}; case $w in */*) w=${w%/*}/;; *) w=.;; esac;; esac
  case $w in '~'*) PS+=("$2/$w"); PD+=("$3");; esac
  joinp "$2" "$w"; PS+=("$JP"); PD+=("$3")
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
  [ $cls = none ] && { case ${WORDS[k]} in *'$'*) MUT=1; each_base . 0;; esac; return 0; }
  MUT=1
  for w in ${GENV[@]+"${GENV[@]}"}; do each_base "$w" 0; done
  if [ $cls = file ]; then
    for ((j=k+1; j<NW; j++)); do w=${WORDS[j]}
      case $w in --*=*|[A-Za-z_]*=*) w=${w#*=};;
        -*) case $v$w in curl-o?*|wget-[OP]?*) w=${w#-?};; *) continue;; esac;; esac   # -o<path>
      any=1; each_base "$w" "$des"
    done
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

# judge_seg: WORDS/REDS of one simple command, against every dir in BASES.
judge_seg() {
  local i=0 k wp=-1 r w pos
  NW=${#WORDS[@]}
  for r in ${REDS[@]+"${REDS[@]}"}; do case $r in /dev/*) continue;; esac; MUT=1; each_base "$r" 0; done
  # GIT_* anywhere (VAR=, export, declare, env) counts for the rest of the command.
  for w in ${WORDS[@]+"${WORDS[@]}"}; do case $w in GIT_CONFIG=*|GIT_CONFIG_[PCKVGS]*=*) UNRES=1;; GIT_*=*) GENV+=("${w#*=}");; esac; done
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
      '('|')') flush; pend=""; TOK+=("$c"); TYP+=(o);;
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
  MODE=opaque; PS=(); PD=(); UNRES=0; MUT=0; GENV=()
  local norm line k t b r i new=0 CDT=() SEGS=()
  # Read the command both with backslash-newline joined and as written, quotes and
  # backslashes dropped: whichever reading the shell uses is covered.
  norm=$(printf '%s' "$cmd" | sed -e ':a' -e '/\\$/{' -e 'N' -e 's/\\\n//' -e 'ba' -e '}' | tr -d "\\\\\"'"
         printf '\n'; printf '%s' "$cmd" | tr -d "\\\\\"'")
  REDS=()
  while IFS= read -r r; do [ -n "$r" ] && REDS+=("$r"); done < <(printf '%s\n' "$norm" | sed -E 's/[0-9]*[<>]&[0-9-]+//g' \
    | grep -oE '[0-9]*>>?[|&]?[[:space:]]*[^[:space:];&|()<>]+' | sed -E 's/^[0-9]*>>?[|&]?[[:space:]]*//')
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

# The opt-out markers are the user's to edit, whoever asks and from wherever. (Coarse
# on Bash: any command naming one with a writing word, e.g. git log -- .claude/no-isolation.)
if [ "$tool" = Bash ]; then
  case $(printf '%s' "$cmd_raw" | tr -d "\\\\\"'") in *no-isolation*) mut_ev "$cmd_raw" && deny "$SELF";; esac
else
  lexnorm "$ap"; case $LEX in */.claude/no-isolation|*/hooks/no-isolation-repos) deny "$SELF";; esac
fi

dir=$cwd
[ -n "$path" ] && dir=$(dirname "$ap")
if [ ! -d "$dir" ]; then   # new dirs: the nearest existing parent, read lexically, if in a repo
  lexnorm "$dir"; dir=$LEX; while [ ! -d "$dir" ]; do dir=${dir%/*}; dir=${dir:-/}; done
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || dir=$cwd
fi

# Outside any work tree only a path into a main checkout is refused (Bash only).
INREPO=1; git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { [ "$tool" = Bash ] || allow; INREPO=0; }
top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
[ -n "$top" ] && [ -f "$top/.claude/no-isolation" ] && allow

# Global opt-out list, kept outside any repo so it needs no in-repo marker file.
# A line may carry an expiry — "<path> until YYYY-MM-DD" — and stops matching
# after that day, so a temporary exemption reverts to guarded on its own.
exempt=~/.claude/hooks/no-isolation-repos
if [ -f "$exempt" ]; then
  common_root=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  main_top=${common_root%/.git}
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
    [ -n "$top" ] && { [ "$line" = "$top" ] || [ "$line" = "$main_top" ]; } && allow
  done < "$exempt"
fi

pdir=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || pdir=$dir

if [ "$tool" = "Bash" ]; then
  # Cap first, before anything that grows faster than the input.
  if [ ${#cmd_raw} -gt 16384 ]; then mut_ev "$cmd_raw" && deny "$LONG"; allow; fi
  case $cmd in *'<<'*) strip_heredocs;; esac   # bodies of allowlisted quoted heredocs
  MODE=structured; MUT=0
  case $cmd in *[\\\$\`]*|*'<<'*) opaque;; *) structured || opaque;; esac
else
  # Rule 2: the nearest existing parent of file_path, as written and normalized (batch_resolve).
  PS=("${ap:-$pdir}"); PD=(0); MUT=1; UNRES=0
fi

batch_resolve() {
  local i p d self
  for ((i=0; i<${#PS[@]}; i++)); do
    LEX=""
    case ${PS[i]} in */.|*/./*|*/..|*/../*) lexnorm "${PS[i]}";; esac
    for p in "${PS[i]}" ${LEX:+"$LEX"}; do
      while [ ${#p} -gt 1 ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
      d=$p; self=1
      until cd -P -- "$d" 2>/dev/null; do self=0; d=${d%/*}; [ -n "$d" ] || d=/; done
      printf '%s\t%s\t%s\n' "$PWD" "$self" "${PD[i]}"
    done
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
info "$pdir"; CWD_C=$IMC; MAINS=("$IMT")
for b in ${BASES[@]+"${BASES[@]}"}; do info "$b"; MAINS+=("$IMT"); done
HOMEP=$(cd -P -- "$HOME" 2>/dev/null && pwd -P) || HOMEP=$HOME
HIT=0; R1HIT=0
if [ ${#PS[@]} -gt 0 ] && [ $TOO_MANY = 0 ]; then
  while IFS=$'\t' read -r L self des; do
    [ -n "$L" ] || continue
    info "$L"; [ $TOO_MANY = 1 ] && break
    [ "$IM" = 1 ] && HIT=1
    { [ -n "$IMC" ] && [ "$IMC" = "$CWD_C" ]; } && R1HIT=1
    [ -n "$top" ] && case $L/ in "$top"/*) R1HIT=1;; esac
    if [ "$des" = 1 ] && [ "$self" = 1 ]; then
      [ "$L" = / ] || [ "$L" = "$HOMEP" ] && HIT=1
      for m in "${MAINS[@]}"; do [ -n "$m" ] && case $m/ in "$L"/*) HIT=1;; esac; done
    fi
  done < <(batch_resolve | sort -u)
fi

[ $TOO_MANY = 1 ] && deny "$LONG"
if [ $INREPO = 0 ]; then [ $HIT = 1 ] && { [ -n "$agent" ] && deny "$R2"; deny "$R1"; }; allow; fi
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
