#!/usr/bin/env bash
# Tests for enforce-agent-worktree.sh. Feeds PreToolUse JSON to the hook and
# checks its decision; the hook never runs the command, so nothing here touches
# a real repository. The hook runs under the same bash as this script, so
# `/bin/bash enforce-agent-worktree.test.sh` exercises bash 3.2 on macOS.
# Usage: enforce-agent-worktree.test.sh [path/to/enforce-agent-worktree.sh]
set -u
hook=${1:-$HOME/.claude/hooks/enforce-agent-worktree.sh}
unset CLAUDE_ENFORCE_OFF

# Physical path: macOS mktemp hands out /var/..., a symlink to /private/var/...
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

g() { git -c user.name=t -c user.email=t@example.com -c protocol.file.allow=always "$@"; }
M=$tmp/main
g init -q "$M"
g -C "$M" commit -q --allow-empty -m init
# A linked worktree beside the main checkout, and one nested inside it where
# Claude Code puts them (<main>/.claude/worktrees/<name>).
W_SIB=$tmp/wt-sibling
W_NEST=$M/.claude/worktrees/w
g -C "$M" worktree add -q -b sib "$W_SIB" 2>/dev/null
g -C "$M" worktree add -q -b nest "$W_NEST" 2>/dev/null
# Repositories nested in M that are not linked worktrees: an independent repo
# and a submodule. Writes into them still change M's checkout.
g init -q "$M/vendor/inner"
g -C "$M/vendor/inner" commit -q --allow-empty -m inner
g init -q "$tmp/subsrc"
g -C "$tmp/subsrc" commit -q --allow-empty -m sub
g -C "$M" submodule add -q "$tmp/subsrc" vendor/sub >/dev/null 2>&1
# A directory that exists but cannot be entered.
mkdir -p "$tmp/noperm"
chmod 600 "$tmp/noperm"

# The hook reads ~/.claude/hooks/no-isolation-repos. Point HOME at a private one
# so the real list cannot change the outcome, and use it for opt-out cases.
# opt-future/inner is an unlisted repo inside a listed one; outer/ex a listed repo
# inside an unlisted one.
# Marker fixtures, same shapes: opt-marker/inner unmarked in a marked repo, mko/mk marked
# in an unmarked one, opt-future/mk marked in a listed one, opt-marker/lst listed in a
# marked one; dirmk has a directory where the marker would be, deep a marker below its
# top (deep/sub), and mw a marker only at the top of its linked worktree mww. cm has the
# marker committed, so its worktree cmw holds one too; omw is a worktree of opt-marker.
for r in opt-past opt-future opt-marker opt-future/inner outer outer/ex \
         opt-marker/inner opt-marker/lst mko mko/mk opt-future/mk dirmk deep mw cm; do
  g init -q "$tmp/$r"; g -C "$tmp/$r" commit -q --allow-empty -m i
done
MKF=.claude/no-isolation
mkdir -p "$tmp/cm/.claude"; touch "$tmp/cm/$MKF"; g -C "$tmp/cm" add "$MKF"; g -C "$tmp/cm" commit -q -m m
g -C "$tmp/mw" worktree add -q -b w "$tmp/mww" 2>/dev/null
g -C "$tmp/cm" worktree add -q -b w "$tmp/cmw" 2>/dev/null
g -C "$tmp/opt-marker" worktree add -q -b w "$tmp/omw" 2>/dev/null
mkdir -p "$tmp/home/.claude/hooks" "$tmp/opt-future/sub" "$tmp/opt-marker/sub" "$tmp/dirmk/$MKF" "$tmp/deep/sub/.claude"
for r in opt-marker mko/mk opt-future/mk deep/sub mww; do mkdir -p "$tmp/$r/.claude"; touch "$tmp/$r/$MKF"; done
# Symlinks: sl1's .claude points out of the repo at a dir holding a marker; sl2's marker
# is a symlink to a file outside. Neither counts, on the cwd or as a target.
for r in sl1 sl2; do g init -q "$tmp/$r"; g -C "$tmp/$r" commit -q --allow-empty -m i; done
mkdir -p "$tmp/shared/cfg" "$tmp/sl2/.claude"; touch "$tmp/shared/cfg/${MKF#*/}" "$tmp/shared/f"
ln -s "$tmp/shared/cfg" "$tmp/sl1/.claude"; ln -s "$tmp/shared/f" "$tmp/sl2/$MKF"
touch "$tmp/opt-marker/.claude/settings.json"
# Layouts with no main top a worktree can find: a bare repo's worktree bare/wt1, and sgw, a
# worktree of sg whose git dir is sep/sg.git. Markers sit beside the git dirs (bare/,
# sep/: outside any checkout) and at every checkout top, as a committed one would.
g init -q "$tmp/bsrc"; g -C "$tmp/bsrc" commit -q --allow-empty -m i
g clone -q --bare "$tmp/bsrc" "$tmp/bare/repo.git" 2>/dev/null
g -C "$tmp/bare/repo.git" worktree add -q "$tmp/bare/wt1" 2>/dev/null
mkdir -p "$tmp/sep"; g init -q --separate-git-dir "$tmp/sep/sg.git" "$tmp/sg"; g -C "$tmp/sg" commit -q --allow-empty -m i
g -C "$tmp/sg" worktree add -q -b w "$tmp/sgw" 2>/dev/null
for r in bare bare/wt1 sep sg sgw; do mkdir -p "$tmp/$r/.claude"; touch "$tmp/$r/$MKF"; done
# Names APFS takes for the marker's: fold1 has no-iſolation (U+017F), fold2 the upper case.
for r in fold1 fold2; do g init -q "$tmp/$r"; g -C "$tmp/$r" commit -q --allow-empty -m i; mkdir -p "$tmp/$r/.claude"; done
touch "$tmp/fold1/.claude/no-i$(printf '\305\277')olation" "$tmp/fold2/.claude/NO-ISOLATION"
# Symlinks into M placed earlier in a marked and in a listed repo (relative, dangling),
# and one inside the marked repo pointing within it.
ln -s ../main/f "$tmp/opt-marker/lf"; ln -s ../main/f "$tmp/opt-future/lf"; ln -s sub "$tmp/opt-marker/ls"
ln -s ../../main/f "$tmp/opt-marker/sub/lf0"; ln -s lf0 "$tmp/opt-marker/sub/lf1"
mkdir -p "$tmp/o2/d"   # ../main from here is not M
MK0=$tmp/opt-marker
# Chains into M: c1..c10 (10 links) and hc/h1..h31 (31) in MK, k1 -> k2 -> h1 (33, past
# the kernel's 32: the write fails there, the hook denies anyway); lw in W points into M;
# q1..q9 -> qf in W is a legit chain; many2 holds 260 links outside any repo.
for i in $(seq 1 9); do ln -s "c$((i+1))" "$MK0/c$i"; done; ln -s ../main/f "$MK0/c10"
mkdir -p "$MK0/hc"; for i in $(seq 1 30); do ln -s "h$((i+1))" "$MK0/hc/h$i"; done; ln -s ../../main/f "$MK0/hc/h31"
ln -s k2 "$MK0/hc/k1"; ln -s h1 "$MK0/hc/k2"
ln -s ../main/f "$W_SIB/lw"; touch "$W_SIB/qf"; for i in $(seq 1 8); do ln -s "q$((i+1))" "$W_SIB/q$i"; done; ln -s qf "$W_SIB/q9"
mkdir -p "$tmp/many2"; for i in $(seq 1 260); do ln -s x "$tmp/many2/l$i"; done
# MK/g/ld is a dir link into M, la <-> lb a loop; W/ldang dangles within W; out/q holds
# plain files to copy, out/zz links to M/f outside any repo (a hard link source).
mkdir -p "$MK0/g" "$tmp/out/q"; ln -s ../../main "$MK0/g/ld"; ln -s lb "$MK0/g/la"; ln -s la "$MK0/g/lb"
ln -s newfile "$W_SIB/ldang"; echo x > "$tmp/out/q/lf"; echo x > "$tmp/out/q/ok"; ln -s ../main/f "$tmp/out/zz"
ln -s ../main/f "$MK0/zé"   # one character in UTF-8, two bytes in C: z? matches it in zsh
cat >"$tmp/home/.claude/hooks/no-isolation-repos" <<EOF
# test list
$tmp/opt-past until 2000-01-01
$tmp/opt-future/ until 2999-12-31
$tmp/outer/ex
$tmp/opt-marker/lst
EOF
# HOMEs with no list file and with an empty one: the marker alone must carry the rules.
mkdir -p "$tmp/home2" "$tmp/home3/.claude/hooks"
: >"$tmp/home3/.claude/hooks/no-isolation-repos"
export HOME=$tmp/home

pass=0 fail=0
R1=メインスレッド
R2=メインチェックアウト

# check <label> <allow|deny> <reason-substring|""> <json>
check() {
  local label=$1 want=$2 sub=$3 json=$4 out rc err dec got
  out=$(printf '%s' "$json" | "$BASH" "$hook" 2>"$tmp/stderr"); rc=$?
  err=$(cat "$tmp/stderr")
  dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  if [ -z "$out" ] && [ "$rc" = 0 ] && [ -z "$err" ]; then got=allow
  elif [ "$dec" = deny ] && [ "$rc" = 0 ]; then got=deny
  else got="error(rc=$rc out=${out:0:80} err=${err:0:200})"
  fi
  if [ "$got" = "$want" ] && { [ "$want" = allow ] || [ -z "$sub" ] || [[ $out == *"$sub"* ]]; }; then
    pass=$((pass+1)); printf 'PASS  %s\n' "$label"
  else
    fail=$((fail+1)); printf 'FAIL  %s  (want %s%s, got %s)\n' "$label" "$want" "${sub:+ /$sub/}" "$got"
  fi
}

bash_json() {  # <agent|""> <cwd> <command>
  jq -n --arg a "$1" --arg c "$2" --arg x "$3" \
    '{tool_name:"Bash",cwd:$c,tool_input:{command:$x}} + (if $a == "" then {} else {agent_id:$a} end)'
}
write_json() {  # <agent|""> <cwd> <file_path>
  jq -n --arg a "$1" --arg c "$2" --arg p "$3" \
    '{tool_name:"Write",cwd:$c,tool_input:{file_path:$p,content:"x"}} + (if $a == "" then {} else {agent_id:$a} end)'
}

NL=$'\n'
for layout in sibling nested; do
  if [ "$layout" = sibling ]; then W=$W_SIB; else W=$W_NEST; fi
  t() { check "[$layout] $1" "$2" "$3" "$4"; }
  # Rule 2 follows the directory a segment acts on.
  t " 1 cwd=M git -C W pull"                 allow ""  "$(bash_json a1 "$M" "git -C $W pull --ff-only")"
  t " 2 cwd=M cd W && git pull"              allow ""  "$(bash_json a1 "$M" "cd $W && git pull --ff-only")"
  t " 3 cwd=M git -C W commit"               allow ""  "$(bash_json a1 "$M" "git -C $W commit -m x")"
  t " 4 cwd=M git -CW commit (glued)"        allow ""  "$(bash_json a1 "$M" "git -C$W commit -m x")"
  t " 5 cwd=M git commit"                    deny "$R2" "$(bash_json a1 "$M" "git commit -m x")"
  t " 6 cwd=W git -C M commit"               deny "$R2" "$(bash_json a1 "$W" "git -C $M commit -m x")"
  t " 7 cwd=M cd W && git -C M commit"       deny "$R2" "$(bash_json a1 "$M" "cd $W && git -C $M commit -m x")"
  t " 8 cwd=M (cd W && commit) && commit"    deny "$R2" "$(bash_json a1 "$M" "(cd $W && git commit -m x) && git commit -m y")"
  t " 8b cwd=M (cd W && commit)"             allow ""  "$(bash_json a1 "$M" "(cd $W && git commit -m x)")"
  t " 9 cwd=M git --work-tree=W commit"      deny "$R2" "$(bash_json a1 "$M" "git --work-tree=$W commit -m x")"
  # Conservative: a cd that fails leaves the shell in the cwd (M).
  t "10 cwd=M cd /nonexistent && commit"     deny "$R2" "$(bash_json a1 "$M" "cd /nonexistent && git commit -m x")"
  t "11 cwd=W git pull"                      allow ""  "$(bash_json a1 "$W" "git pull --ff-only")"
  t "12 no agent cwd=M git -C W pull"        deny "$R1" "$(bash_json "" "$M" "git -C $W pull --ff-only")"
  t "13 no agent cwd=W git pull"             deny "$R1" "$(bash_json "" "$W" "git pull --ff-only")"
  t "14a cwd=M git -C M log"                 allow ""  "$(bash_json a1 "$M" "git -C $M log -1")"
  t "14b cwd=M grep -rn x M"                 allow ""  "$(bash_json a1 "$M" "grep -rn x $M")"
  t "15a cwd=M echo > /tmp/outside"          allow ""  "$(bash_json a1 "$M" "echo x > /tmp/outside")"
  t "15b cwd=M cd W && echo > a.txt"         allow ""  "$(bash_json a1 "$M" "cd $W && echo x > a.txt")"
  t "15c cwd=M echo > a.txt"                 deny "$R2" "$(bash_json a1 "$M" "echo x > a.txt")"
  t "16a Write no agent under W"             deny "$R1" "$(write_json "" "$M" "$W/a.txt")"
  t "16b Write agent under M"                deny "$R2" "$(write_json a1 "$M" "$M/a.txt")"
  t "16c Write agent under W"                allow ""  "$(write_json a1 "$M" "$W/a.txt")"
  # Escapes that must stay closed, and commands the guard must keep allowing.
  t "x1 cwd=M cd W && rm M/a"                deny "$R2" "$(bash_json a1 "$M" "cd $W && rm $M/a")"
  t "x2 cwd=M cd W | git commit (pipeline)"  deny "$R2" "$(bash_json a1 "$M" "cd $W | git commit -m x")"
  # Conservative: if cd W fails the commit runs in M, so || never tracks.
  t "x3 cwd=M cd W || git commit"            deny "$R2" "$(bash_json a1 "$M" "cd $W || git commit -m x")"
  t "x4 cwd=M cd \"W\" && git commit"        allow ""  "$(bash_json a1 "$M" "cd \"$W\" && git commit -m x")"
  t "x5 cwd=M git -C W status (read)"        allow ""  "$(bash_json a1 "$M" "git -C $W status")"
  t "x6 cwd=M bash /tmp/x.sh arg"            allow ""  "$(bash_json a1 "$M" "bash /tmp/x.sh arg")"
  t "x7 cwd=M cp /tmp/a /tmp/b"              allow ""  "$(bash_json a1 "$M" "cp /tmp/a /tmp/b")"
  t "x8 cwd=M echo x 2>&1 > /tmp/o"          allow ""  "$(bash_json a1 "$M" "echo x 2>&1 > /tmp/o")"
  t "x9 cwd=M git -C W add . && git -C W commit" allow "" "$(bash_json a1 "$M" "git -C $W add . && git -C $W commit -m x")"
  t "x10 cwd=M find . -exec rm"              deny "$R2" "$(bash_json a1 "$M" "find . -name '*.o' -exec rm {} +")"
  t "x11 cwd=M cd W && npm install"          allow ""  "$(bash_json a1 "$M" "cd $W && npm install")"
  t "x12 cwd=M npm install"                  deny "$R2" "$(bash_json a1 "$M" "npm install")"
  t "x13 cwd=M cd W; git commit"             allow ""  "$(bash_json a1 "$M" "cd $W; git commit -m x")"
  t "x14 cwd=M cd W && commit \"(a; b)\""    allow ""  "$(bash_json a1 "$M" "cd $W && git commit -m \"fix (scope); rest\" && git push")"
  t "x15 cwd=W commit -F - <<EOF"            allow ""  "$(bash_json a1 "$W" "git commit -F - <<'EOF'${NL}rm stale${NL}EOF")"
  t "x16 cwd=M cd W && make"                 allow ""  "$(bash_json a1 "$M" "cd $W && make")"

  # Must-fix 1: a cd that cannot be followed reverts to the cwd.
  t "m1a cd W && cd - && commit"             deny "$R2" "$(bash_json a1 "$M" "cd $W && cd - && git commit -m x")"
  t "m1b cd W; cd -; commit"                 deny "$R2" "$(bash_json a1 "$M" "cd $W; cd -; git commit -m x")"
  t "m1c cd W && cd -- M && commit"          deny "$R2" "$(bash_json a1 "$M" "cd $W && cd -- $M && git commit -m x")"
  t "m1d cd W && cd \$OLDPWD && commit"      deny "$R2" "$(bash_json a1 "$M" "cd $W && cd \$OLDPWD && git commit -m x")"
  t "m1e cd W && pushd M && commit"          deny "$R2" "$(bash_json a1 "$M" "cd $W && pushd $M && git commit -m x")"
  t "m1f cd W && eval \"cd M\" && commit"    deny "$R2" "$(bash_json a1 "$M" "cd $W && eval \"cd $M\" && git commit -m x")"
  t "m1g cd W && bash -c \"cd M && commit\"" deny "$R2" "$(bash_json a1 "$M" "cd $W && bash -c \"cd $M && git commit -m x\"")"
  t "m1h cd W && sh -c 'cd M; commit'"       deny "$R2" "$(bash_json a1 "$M" "cd $W && sh -c 'cd $M; git commit -m x'")"
  t "m1i cd W && git -C \"\$M\" commit"      deny "$R2" "$(bash_json a1 "$M" "cd $W && git -C \"\$M\" commit -m x")"
  t "m1j git -C \"\$PWD/../main\" commit"    deny "$R2" "$(bash_json a1 "$M" "git -C \"\$PWD/../main\" commit -m x")"
  t "m1k cd <no +x dir>; commit"             deny "$R2" "$(bash_json a1 "$M" "cd $tmp/noperm; git commit -m x")"
  t "m1l cd M # && cd W <nl> commit"         deny "$R2" "$(bash_json a1 "$M" "cd $M # && cd $W${NL}git commit -m x")"
  t "m1m cd W && true && cd M && commit"     deny "$R2" "$(bash_json a1 "$M" "cd $W && true && cd $M && git commit -m x")"
  t "m1n cwd=W bash -c \"cd M && commit\""   deny "$R2" "$(bash_json a1 "$W" "bash -c \"cd $M && git commit -m x\"")"
  # Must-fix 2: only a leading chain of cds counts.
  t "m2a echo \"; cd W ;\" ; commit"         deny "$R2" "$(bash_json a1 "$M" "echo \"; cd $W ;\" ; git commit -m x")"
  t "m2b true # ; cd W <nl> commit"          deny "$R2" "$(bash_json a1 "$M" "true # ; cd $W${NL}git commit -m x")"
  t "m2c cat <<X cd W X commit"              deny "$R2" "$(bash_json a1 "$M" "cat <<X${NL}cd $W${NL}X${NL}git commit -m x")"
  t "m2d false && cd W; commit"              deny "$R2" "$(bash_json a1 "$M" "false && cd $W; git commit -m x")"
  t "m2e if false; then cd W; fi; commit"    deny "$R2" "$(bash_json a1 "$M" "if false; then cd $W; fi; git commit -m x")"
  # Must-fix 3: quoted parentheses are not scopes.
  t "m3 echo \")\" ; (cd W ; echo \"(\" ) ; commit" deny "$R2" "$(bash_json a1 "$M" "echo \")\" ; (cd $W ; echo \"(\" ) ; git commit -m x")"
  # Must-fix 4: git's environment and --git-dir.
  t "m4a GIT_WORK_TREE=M git -C W checkout"  deny "$R2" "$(bash_json a1 "$M" "GIT_WORK_TREE=$M git -C $W checkout -- .")"
  t "m4b cd W && GIT_DIR=M/.git ... reset"   deny "$R2" "$(bash_json a1 "$M" "cd $W && GIT_DIR=$M/.git GIT_WORK_TREE=$M git reset --hard")"
  t "m4c git -C W --git-dir=M/.git commit"   deny "$R2" "$(bash_json a1 "$M" "git -C $W --git-dir=$M/.git commit -m x")"
  # Must-fix 5: directory flags of other tools.
  t "m5a cd W && make -C M"                  deny "$R2" "$(bash_json a1 "$M" "cd $W && make -C $M")"
  t "m5b cd W && go -C M mod tidy"           deny "$R2" "$(bash_json a1 "$M" "cd $W && go -C $M mod tidy")"
  t "m5c cd W && cargo --manifest-path M/..." deny "$R2" "$(bash_json a1 "$M" "cd $W && cargo --manifest-path $M/Cargo.toml update")"
  t "m5d cd W && npm --prefix M install"     deny "$R2" "$(bash_json a1 "$M" "cd $W && npm --prefix $M install")"
  # Must-fix 6: what a pipe hands xargs is judged from the cwd too.
  t "m6 cd W && echo M/a | xargs rm"         deny "$R2" "$(bash_json a1 "$M" "cd $W && echo $M/a | xargs rm")"
  # Must-fix 7: .. is resolved, and removing a parent of M removes M.
  t "m7 cd W && rm -rf .."                   deny "$R2" "$(bash_json a1 "$M" "cd $W && rm -rf ..")"
  # Should-fix 9: an explicit path into M is caught from a worktree cwd.
  t "s9a cwd=W rm -rf M"                     deny "$R2" "$(bash_json a1 "$W" "rm -rf $M")"
  t "s9b cwd=W echo x > M/a"                 deny "$R2" "$(bash_json a1 "$W" "echo x > $M/a")"
  t "s9c cwd=W rm -rf .. (parent of M or M)" deny "$R2" "$(bash_json a1 "$W" "rm -rf ..")"

  # Round 2, A: backslash-newline continuation hides the path or the -C.
  t "rA1 cd W && rm \\<nl>M/a"               deny "$R2" "$(bash_json a1 "$M" "cd $W && rm \\${NL}$M/a")"
  t "rA2 cd W && git \\<nl>-C M commit"      deny "$R2" "$(bash_json a1 "$M" "cd $W && git \\${NL}-C $M commit -m x")"
  t "rA3 cwd=W rm \\<nl>M/a"                 deny "$R2" "$(bash_json a1 "$W" "rm \\${NL}$M/a")"
  # Should-fix 2: a glob or brace that expands to a parent of M.
  t "f2a cd W && rm -rf ../*"                deny "$R2" "$(bash_json a1 "$M" "cd $W && rm -rf ../*")"
  t "f2b cwd=W rm -rf ../*"                  deny "$R2" "$(bash_json a1 "$W" "rm -rf ../*")"
  t "f2c cwd=W rm -rf ../ma*"                deny "$R2" "$(bash_json a1 "$W" "rm -rf ../ma*")"
  t "f2d cwd=W rm -rf ../{main,x}"           deny "$R2" "$(bash_json a1 "$W" "rm -rf ../{main,x}")"
  # Should-fix 3: the filesystem root and home.
  t "f3a cwd=W rm -rf /"                     deny "$R2" "$(bash_json a1 "$W" "rm -rf /")"
  t "f3b cwd=W rm -rf ~"                     deny "$R2" "$(bash_json a1 "$W" "rm -rf ~")"
  # Should-fix 4: wrappers with their own arguments before git.
  t "f4a cwd=W nice -n 5 git -C M commit"    deny "$R2" "$(bash_json a1 "$W" "nice -n 5 git -C $M commit -m x")"
  t "f4b cwd=W timeout 5 git -C M commit"    deny "$R2" "$(bash_json a1 "$W" "timeout 5 git -C $M commit -m x")"
  t "f4c cd W && nice -n 5 git -C M commit"  deny "$R2" "$(bash_json a1 "$M" "cd $W && nice -n 5 git -C $M commit -m x")"
  # Should-fix 5: other ways to write into M.
  t "f5a cwd=W find M -delete"               deny "$R2" "$(bash_json a1 "$W" "find $M -delete")"
  t "f5b cwd=W tar -xf x -C M"               deny "$R2" "$(bash_json a1 "$W" "tar -xf x.tar -C $M")"
  t "f5c cwd=W git -c core.worktree=M checkout" deny "$R2" "$(bash_json a1 "$W" "git -c core.worktree=$M checkout -- .")"
  t "f5d cwd=W unzip x.zip -d M"             deny "$R2" "$(bash_json a1 "$W" "unzip x.zip -d $M")"
  t "f5e cwd=W curl -o M/a URL"              deny "$R2" "$(bash_json a1 "$W" "curl -o $M/a http://x")"
  t "f5f cwd=M git -C W worktree add M/sub"  deny "$R2" "$(bash_json a1 "$M" "git -C $W worktree add $M/sub/new")"
  t "f5g cwd=M git -C W push M"              deny "$R2" "$(bash_json a1 "$M" "git -C $W push $M sib:main")"
  t "f5h cwd=W GIT_DIR=M/.git git commit"    deny "$R2" "$(bash_json a1 "$W" "GIT_DIR=$M/.git git commit -m x")"
  # Things the structured mode must keep allowing.
  t "k1 cwd=M cd W && find . -name x -delete" allow "" "$(bash_json a1 "$M" "cd $W && find . -name x -delete")"
  t "k2 cwd=W rm -rf node_modules dist"      allow ""  "$(bash_json a1 "$W" "rm -rf node_modules dist")"
  t "k3 cwd=M git -C W push origin sib"      allow ""  "$(bash_json a1 "$M" "git -C $W push origin sib")"
  t "k4 cwd=M cd W && git commit -m \"a | b\"" allow "" "$(bash_json a1 "$M" "cd $W && git commit -m \"a | b\"")"
  t "k5 cwd=M env X=1 true; git -C W commit" allow "" "$(bash_json a1 "$M" "env X=1 true; git -C $W commit -m x")"
done

# Must-fix 8: a nested repo is exempt only when it is a linked worktree.
check "m8a cwd=M rm M/vendor/inner/a"        deny "$R2" "$(bash_json a1 "$M" "rm $M/vendor/inner/a")"
check "m8b cwd=M echo > vendor/inner/a"      deny "$R2" "$(bash_json a1 "$M" "echo x > vendor/inner/a")"
check "m8c cwd=M rm M/vendor/sub/a (submodule)" deny "$R2" "$(bash_json a1 "$M" "rm $M/vendor/sub/a")"
check "m8d cwd=M echo > vendor/sub/a"        deny "$R2" "$(bash_json a1 "$M" "echo x > vendor/sub/a")"
check "m8e cwd=M echo > N/a (linked, exempt)" allow ""  "$(bash_json a1 "$M" "echo x > $W_NEST/a")"
check "m8f Write agent M/vendor/inner/a"     deny "$R2" "$(write_json a1 "$M" "$M/vendor/inner/a")"
# Should-fix 9 from a nested worktree.
check "s9d cwd=N rm ../../../a"              deny "$R2" "$(bash_json a1 "$W_NEST" "rm ../../../a")"
check "s9e cwd=N echo x > M/a"               deny "$R2" "$(bash_json a1 "$W_NEST" "echo x > $M/a")"
check "s9f cwd=N echo x > a"                 allow ""  "$(bash_json a1 "$W_NEST" "echo x > a")"

# The main checkout reached through a symlink must still count as main.
ln -s "$M" "$tmp/main-link"
check "s1 Write agent under symlinked M"     deny "$R2" "$(write_json a1 "$tmp/main-link" "$tmp/main-link/a.txt")"
check "s2 cwd=symlinked M git commit"        deny "$R2" "$(bash_json a1 "$tmp/main-link" "git commit -m x")"

# Opt-out list and marker, read from the private HOME above.
check "o1 until past: guarded"               deny "$R2" "$(bash_json a1 "$tmp/opt-past" "git commit -m x")"
check "o2 until past: guarded (no agent)"    deny "$R1" "$(bash_json "" "$tmp/opt-past" "git commit -m x")"
check "o3 until future: exempt"              allow ""  "$(bash_json "" "$tmp/opt-future" "git commit -m x")"
check "o4 until future: exempt (Write)"      allow ""  "$(write_json "" "$tmp/opt-future" "$tmp/opt-future/a")"
check "o5 .claude/no-isolation: exempt"      allow ""  "$(bash_json "" "$tmp/opt-marker" "git commit -m x")"
check "o6 not listed: guarded"               deny "$R1" "$(bash_json "" "$M" "git commit -m x")"
# The list is also judged on each Bash target, as Write judges it on the file's dir: a
# path into a listed main checkout counts as one outside any repo. Each other target
# is judged as before, so one path into M still denies. The .claude/no-isolation marker
# counts the same way (mk* below).
OF=$tmp/opt-future
mkdir -p "$tmp/out"
check "o7 cwd=M cd opt-future && rm f"       allow ""  "$(bash_json a1 "$M" "cd $OF && rm f")"
check "o8 cwd=M git -C opt-future commit"    allow ""  "$(bash_json a1 "$M" "git -C $OF commit -m x")"
check "o9 cwd=W echo > opt-marker/a"         allow ""  "$(bash_json a1 "$W_SIB" "echo x > $tmp/opt-marker/a")"
check "o10 Write agent cwd=M opt-future/a"   allow ""  "$(write_json a1 "$M" "$OF/a")"
check "o11 cwd=M cd opt-future && touch f"   allow ""  "$(bash_json a1 "$M" "cd $OF && touch f")"
check "o12 cwd=M cd opt-future && git add f && commit" allow "" "$(bash_json a1 "$M" "cd $OF && git add f && git commit -m x")"
check "o13 cwd=W echo > opt-future/a"        allow ""  "$(bash_json a1 "$W_SIB" "echo x > $OF/a")"
check "o14 cwd=M git -C opt-future commit && git commit" deny "$R2" "$(bash_json a1 "$M" "git -C $OF commit -m x && git commit -m y")"
check "o15 cwd=W touch opt-future/a M/a"     deny "$R2" "$(bash_json a1 "$W_SIB" "touch $OF/a $M/a")"
check "o16 cwd=W git -C opt-future --work-tree=M checkout" deny "$R2" "$(bash_json a1 "$W_SIB" "git -C $OF --work-tree=$M checkout -- .")"
check "o17 cwd=W git -C opt-past commit (expired)" deny "$R2" "$(bash_json a1 "$W_SIB" "git -C $tmp/opt-past commit -m x")"
check "o18 cwd=W rm -rf opt-future/\$x"         deny "確認できません" "$(bash_json a1 "$W_SIB" "rm -rf $OF/\$x")"
check "o19 cwd=W echo > opt-future/inner/a (unlisted, nested)" deny "$R2" "$(bash_json a1 "$W_SIB" "echo x > $OF/inner/a")"
check "o20 cwd=W echo > outer/ex/a (listed, in unlisted)" deny "$R2" "$(bash_json a1 "$W_SIB" "echo x > $tmp/outer/ex/a")"
# Destructive verbs: inside a listed checkout they pass; the checkout itself, a parent
# of it, /, ~ and a parent of any other main checkout stay refused.
check "o21 cwd=W rm -rf opt-future/sub"      allow ""  "$(bash_json a1 "$W_SIB" "rm -rf $OF/sub")"
check "o22 cwd=W rm -rf opt-future"          deny "$R2" "$(bash_json a1 "$W_SIB" "rm -rf $OF")"
check "o23 cwd=W rm -rf opt-future/"         deny "$R2" "$(bash_json a1 "$W_SIB" "rm -rf $OF/")"
check "o24 cwd=M cd opt-future && rm -rf ."  deny "$R2" "$(bash_json a1 "$M" "cd $OF && rm -rf .")"
check "o25 cwd=M cd opt-future && rm -rf .." deny "$R2" "$(bash_json a1 "$M" "cd $OF && rm -rf ..")"
check "o26 cwd=out rm -rf opt-future (no agent)" deny "$R1" "$(bash_json "" "$tmp/out" "rm -rf $OF")"
check "o27 cwd=W rm -rf opt-future/sub M/a"  deny "$R2" "$(bash_json a1 "$W_SIB" "rm -rf $OF/sub $M/a")"
# Outside any repo, a path into a listed checkout passes like any other.
check "o28 cwd=out cd opt-future && commit (no agent)" allow "" "$(bash_json "" "$tmp/out" "cd $OF && git commit -m x")"
check "o29 cwd=out git -C opt-future commit"  allow ""  "$(bash_json a1 "$tmp/out" "git -C $OF commit -m x")"
check "o30 cwd=out git -C opt-past commit"    deny "$R2" "$(bash_json a1 "$tmp/out" "git -C $tmp/opt-past commit -m x")"
# No agent in a guarded repo: rule 1's original reading still refuses any git commit.
check "o31 cwd=M git -C opt-future commit (no agent)" deny "$R1" "$(bash_json "" "$M" "git -C $OF commit -m x")"
check "o32 cwd=M echo > opt-future/a (no agent)" allow "" "$(bash_json "" "$M" "echo x > $OF/a")"
# The opaque reading ($ \ ` <<) marks every path word destructive, cd and -C operands
# too, so there the listed checkout itself is not refused as a removal: a commit with
# a heredoc or variable message passes. From cwd=M the cwd still counts, so it denies.
HM="\"\$(cat <<'EOF'${NL}msg${NL}EOF${NL})\""
check "o33 cwd=W git -C opt-future commit -m heredoc" allow "" "$(bash_json a1 "$W_SIB" "git -C $OF commit -m $HM")"
check "o34 cwd=out cd opt-future && commit -m heredoc" allow "" "$(bash_json a1 "$tmp/out" "cd $OF && git commit -m $HM")"
check "o35 cwd=W git -C opt-future commit -m \"\$MSG\"" allow "" "$(bash_json a1 "$W_SIB" "git -C $OF commit -m \"\$MSG\"")"
check "o36 cwd=M git -C opt-future commit -m heredoc" deny "$R2" "$(bash_json a1 "$M" "git -C $OF commit -m $HM")"
check "o37 cwd=W cd opt-future && rm -rf \"\$x\"/a" deny "確認できません" "$(bash_json a1 "$W_SIB" "cd $OF && rm -rf \"\$x\"/a")"
check "o38 cwd=W x=\$y; rm -rf opt-future (opaque: passes)" allow "" "$(bash_json a1 "$W_SIB" "x=\$y; rm -rf $OF")"
check "o39 cwd=W x=\$y; cd opt-future && rm -rf .. (opaque)" deny "$R2" "$(bash_json a1 "$W_SIB" "x=\$y; cd $OF && rm -rf ..")"
# git clean -x removes untracked nested repos (opt-future/inner) the lookup never sees,
# so a command with git clean gets no help from the list on any target. From the
# listed cwd itself it still passes.
check "o40 cwd=W git -C opt-future clean -ffdx" deny "$R2" "$(bash_json a1 "$W_SIB" "git -C $OF clean -ffdx")"
check "o41 cwd=W git -C opt-future clean -fd"   deny "$R2" "$(bash_json a1 "$W_SIB" "git -C $OF clean -fd")"
check "o42 cwd=out cd opt-future && git clean -fdx" deny "$R2" "$(bash_json a1 "$tmp/out" "cd $OF && git clean -fdx")"
check "o43 cwd=opt-future git clean -ffdx"      allow ""  "$(bash_json a1 "$OF" "git clean -ffdx")"
# Once the list has cleared a path, an unresolved target denies outside a repo too: the
# variable may name the main checkout the listed one sits beside. Without the list
# involved, out-of-repo work with a variable target passes as before.
check "o44 cwd=out x=M; cd opt-future && rm -rf \"\$x\"/f" deny "確認できません" "$(bash_json a1 "$tmp/out" "x=$M; cd $OF && rm -rf \"\$x\"/f")"
check "o45 same, no agent"                      deny "$R1" "$(bash_json "" "$tmp/out" "x=$M; cd $OF && rm -rf \"\$x\"/f")"
check "o46 cwd=out x=/tmp/q; rm -rf \"\$x\"/f"  allow ""  "$(bash_json a1 "$tmp/out" "x=/tmp/q; rm -rf \"\$x\"/f")"
check "o47 cwd=out x=/tmp/q; rm -rf \"\$x\"/f (no agent)" allow "" "$(bash_json "" "$tmp/out" "x=/tmp/q; rm -rf \"\$x\"/f")"
# NOEX is coarse: the words clean / submodule anywhere, a verb or git subcommand from a
# variable, or git config from the environment leave every target judged without the list.
check "o48 cwd=W G=git; \$G -C opt-future clean -ffdx" deny "$R2" "$(bash_json a1 "$W_SIB" "G=git; \$G -C $OF clean -ffdx")"
check "o49 cwd=W git -C opt-future submodule foreach git clean -ffdx" deny "$R2" "$(bash_json a1 "$W_SIB" "git -C $OF submodule foreach git clean -ffdx")"
check "o50 cwd=W git -C opt-future submodule deinit -f --all" deny "$R2" "$(bash_json a1 "$W_SIB" "git -C $OF submodule deinit -f --all")"
check "o51 cwd=W git -C opt-future commit -m \"clean up\"" deny "$R2" "$(bash_json a1 "$W_SIB" "git -C $OF commit -m \"clean up\"")"
check "o52 cwd=W git -C opt-future c\\lean -ffdx" deny "" "$(bash_json a1 "$W_SIB" "git -C $OF c\\lean -ffdx")"
# An alias or included config on the command line, config from the environment, or a
# subcommand from a variable makes git a writer to a place not followed: denied for any
# repo, listed or not (on HEAD these passed even against M).
U1=確認できません
check "o53 cwd=W git -C opt-future -c alias.x=clean x -ffdx" deny "$U1" "$(bash_json a1 "$W_SIB" "git -C $OF -c alias.x=clean x -ffdx")"
check "o54 cwd=W git -C M -c alias.x=clean x -ffdx" deny "$U1" "$(bash_json a1 "$W_SIB" "git -C $M -c alias.x=clean x -ffdx")"
check "o55 cwd=W git -C M -c Alias.x=... x" deny "$U1" "$(bash_json a1 "$W_SIB" "git -C $M -c Alias.x=clean x -ffdx")"
check "o56 cwd=W git -C M -calias.x=... x (glued)" deny "$U1" "$(bash_json a1 "$W_SIB" "git -C $M -calias.x=clean x -ffdx")"
check "o57 cwd=W git -C M --config-env=alias.x=V x" deny "$U1" "$(bash_json a1 "$W_SIB" "git -C $M --config-env=alias.x=V x -ffdx")"
check "o58 cwd=W git -C M -c include.path=/tmp/c x" deny "$U1" "$(bash_json a1 "$W_SIB" "git -C $M -c include.path=/tmp/c x")"
check "o59 cwd=M git -c alias.x=clean x (no agent)" deny "$R1" "$(bash_json "" "$M" "git -c alias.x=clean x -ffdx")"
check "o60 cwd=W git -C M \$s -ffdx"       deny "$R2" "$(bash_json a1 "$W_SIB" "git -C $M \$s -ffdx")"
check "o61 cwd=W GIT_CONFIG_COUNT=1 git -C M x" deny "$U1" "$(bash_json a1 "$W_SIB" "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.x GIT_CONFIG_VALUE_0=clean git -C $M x -ffdx")"
check "o62 cwd=W git -c color.ui=never -C opt-future add f" allow "" "$(bash_json a1 "$W_SIB" "git -c color.ui=never -C $OF add f")"
check "o63 cwd=W git -C opt-future add f"   allow ""  "$(bash_json a1 "$W_SIB" "git -C $OF add f")"
# The marker at a main checkout's top counts per target exactly as the list does.
MK=$tmp/opt-marker
mk() {  # mk <label> <want> <reason> <agent> <cwd> <command>, under each of the three HOMEs
  local h
  for h in home home2 home3; do HOME=$tmp/$h; check "$1 [$h]" "$2" "$3" "$(bash_json "$4" "$5" "$6")"; done
  HOME=$tmp/home
}
mk "mk1 cwd=W git -C MK commit"                allow "" a1 "$W_SIB" "git -C $MK commit -m x"
mk "mk2 cwd=W git -C MK add f"                 allow "" a1 "$W_SIB" "git -C $MK add f"
mk "mk3 cwd=W echo > MK/a"                     allow "" a1 "$W_SIB" "echo x > $MK/a"
mk "mk4 cwd=M git -C MK commit"                allow "" a1 "$M" "git -C $MK commit -m x"
mk "mk5 cwd=M cd MK && git add f && commit"    allow "" a1 "$M" "cd $MK && git add f && git commit -m x"
mk "mk6 cwd=M echo > MK/a"                     allow "" a1 "$M" "echo x > $MK/a"
mk "mk7 cwd=out git -C MK commit"              allow "" a1 "$tmp/out" "git -C $MK commit -m x"
mk "mk8 cwd=out cd MK && commit (no agent)"    allow "" "" "$tmp/out" "cd $MK && git commit -m x"
mk "mk9 cwd=out echo > MK/a (no agent)"        allow "" "" "$tmp/out" "echo x > $MK/a"
mk "mk10 cwd=W git -C MK commit -m heredoc"    allow "" a1 "$W_SIB" "git -C $MK commit -m $HM"
mk "mk11 cwd=W touch MK/a M/a"                 deny "$R2" a1 "$W_SIB" "touch $MK/a $M/a"
mk "mk12 cwd=M git -C MK commit && git commit" deny "$R2" a1 "$M" "git -C $MK commit -m x && git commit -m y"
mk "mk13 cwd=W git -C MK clean -ffdx"          deny "$R2" a1 "$W_SIB" "git -C $MK clean -ffdx"
mk "mk14 cwd=W git -C MK commit -m \"clean up\"" deny "$R2" a1 "$W_SIB" "git -C $MK commit -m \"clean up\""
mk "mk15 cwd=W G=git; \$G -C MK commit"        deny "$R2" a1 "$W_SIB" "G=git; \$G -C $MK commit -m x"
mk "mk16 cwd=W git -C MK submodule update"     deny "$R2" a1 "$W_SIB" "git -C $MK submodule update --init"
mk "mk17 cwd=out x=M; cd MK && rm -rf \"\$x\"/f" deny "$U1" a1 "$tmp/out" "x=$M; cd $MK && rm -rf \"\$x\"/f"
mk "mk18 same, no agent"                       deny "$R1" "" "$tmp/out" "x=$M; cd $MK && rm -rf \"\$x\"/f"
mk "mk19 cwd=W echo > MK/inner/a (unmarked, nested)" deny "$R2" a1 "$W_SIB" "echo x > $MK/inner/a"
mk "mk20 cwd=W echo > mko/mk/a (marked, in unmarked)" deny "$R2" a1 "$W_SIB" "echo x > $tmp/mko/mk/a"
check "mk21 cwd=W echo > opt-future/mk/a (marked, in listed)" allow "" "$(bash_json a1 "$W_SIB" "echo x > $OF/mk/a")"
check "mk22 cwd=W echo > MK/lst/a (listed, in marked)" allow "" "$(bash_json a1 "$W_SIB" "echo x > $MK/lst/a")"
HOME=$tmp/home2
check "mk23 [home2] cwd=W echo > MK/lst/a (unlisted, in marked)" deny "$R2" "$(bash_json a1 "$W_SIB" "echo x > $MK/lst/a")"
HOME=$tmp/home
mk "mk24 cwd=W rm -rf MK/sub"                  allow "" a1 "$W_SIB" "rm -rf $MK/sub"
mk "mk25 cwd=W rm -rf MK"                      deny "$R2" a1 "$W_SIB" "rm -rf $MK"
mk "mk26 cwd=M cd MK && rm -rf .."             deny "$R2" a1 "$M" "cd $MK && rm -rf .."
mk "mk27 cwd=M git -C MK commit (no agent)"    deny "$R1" "" "$M" "git -C $MK commit -m x"
mk "mk28 cwd=M echo > MK/a (no agent)"         allow "" "" "$M" "echo x > $MK/a"
mk "mk29 cwd=W echo > dirmk/a (marker is a dir)" deny "$R2" a1 "$W_SIB" "echo x > $tmp/dirmk/a"
mk "mk30 cwd=W echo > deep/a (marker below top)" deny "$R2" a1 "$W_SIB" "echo x > $tmp/deep/a"
# Only a main checkout's top counts, as a target and for the cwd. A marker in a linked
# worktree alone opts nothing out (HEAD opted out that cwd); a cwd in a worktree of a
# marked main counts by the main (cmw: committed, so in both; omw: in the main only).
mk "mk31 cwd=W echo > mw/a (marker only in mww)" deny "$R2" a1 "$W_SIB" "echo x > $tmp/mw/a"
mk "mk32 cwd=W echo > mww/a"                   allow "" a1 "$W_SIB" "echo x > $tmp/mww/a"
mk "mk33 cwd=mww echo > M/a (marker only in mww)" deny "$R2" a1 "$tmp/mww" "echo x > $M/a"
mk "mk37 cwd=mww git commit (no agent)"        deny "$R1" "" "$tmp/mww" "git commit -m x"
mk "mk38 cwd=cmw touch M/a (committed marker)"  allow "" a1 "$tmp/cmw" "touch $M/a"
mk "mk39 cwd=cmw git commit (no agent)"        allow "" "" "$tmp/cmw" "git commit -m x"
mk "mk40 cwd=omw touch M/a (marker in main only)" allow "" a1 "$tmp/omw" "touch $M/a"
mk "mk41 cwd=omw git commit (no agent)"        allow "" "" "$tmp/omw" "git commit -m x"
mk "mk42 cwd=W echo > cm/a"                    allow "" a1 "$W_SIB" "echo x > $tmp/cm/a"
# No main top to find from a bare or separate-git-dir worktree: no marker counts for that
# cwd, not beside the git dir and not at the worktree's own top (HEAD let the latter
# opt out the cwd: bw2 and sg2 flip to deny). The main of sg counts, as cwd and target.
mk "bw1 cwd=bare/wt1 touch M/a"                deny "$R2" a1 "$tmp/bare/wt1" "touch $M/a"
mk "bw2 cwd=bare/wt1 touch wt1/a (no agent)"   deny "$R1" "" "$tmp/bare/wt1" "touch $tmp/bare/wt1/a"
mk "bw3 cwd=bare/wt1 rm -rf bare (marked dir)" deny "$R2" a1 "$tmp/bare/wt1" "rm -rf $tmp/bare"
mk "bw4 cwd=bare/wt1 touch wt1/a"              allow "" a1 "$tmp/bare/wt1" "touch $tmp/bare/wt1/a"
mk "sg1 cwd=sgw touch M/a"                     deny "$R2" a1 "$tmp/sgw" "touch $M/a"
mk "sg2 cwd=sgw touch sgw/a (no agent)"        deny "$R1" "" "$tmp/sgw" "touch $tmp/sgw/a"
mk "sg3 cwd=sg git commit (no agent)"          allow "" "" "$tmp/sg" "git commit -m x"
mk "sg4 cwd=W touch sg/a"                      allow "" a1 "$W_SIB" "touch $tmp/sg/a"
mk "sg5 cwd=sgw touch sg/a"                    allow "" a1 "$tmp/sgw" "touch $tmp/sg/a"
mk "sg6 cwd=sgw rm -rf sep (marked dir)"       deny "$R2" a1 "$tmp/sgw" "rm -rf $tmp/sep"
# The marker's entry must be named exactly: no-iſolation and NO-ISOLATION do not count.
mk "fd1 cwd=W echo > fold1/a (U+017F)"         deny "$R2" a1 "$W_SIB" "echo x > $tmp/fold1/a"
mk "fd2 cwd=fold1 git commit (no agent)"       deny "$R1" "" "$tmp/fold1" "git commit -m x"
mk "fd3 cwd=W echo > fold2/a (upper case)"     deny "$R2" a1 "$W_SIB" "echo x > $tmp/fold2/a"
mk "fd4 cwd=fold2 git commit (no agent)"       deny "$R1" "" "$tmp/fold2" "git commit -m x"
# Symlinks: a relative ln -s target is read from the link's dir, and a write through an
# existing link to a file is judged at its target. MK and OF (listed) alike.
mk "ln1 cwd=W cd o2/d && ln -s ../main/f MK/l2 && echo > MK/l2" deny "$R2" a1 "$W_SIB" "cd $tmp/o2/d && ln -s ../main/f $MK/l2 && echo pwn > $MK/l2"
mk "ln2 cwd=o2/d ln -s ../main/f MK/l2"        deny "$R2" a1 "$tmp/o2/d" "ln -s ../main/f $MK/l2"
mk "ln3 cwd=W echo > MK/lf (link into M)"      deny "$R2" a1 "$W_SIB" "echo pwn > $MK/lf"
mk "ln4 cwd=W cd o2/d && ln -s ../main/f OF/l2" deny "$R2" a1 "$W_SIB" "cd $tmp/o2/d && ln -s ../main/f $tmp/opt-future/l2"
mk "ln5 cwd=W echo > OF/lf (link into M)"      deny "$R2" a1 "$W_SIB" "echo pwn > $tmp/opt-future/lf"
mk "ln6 cwd=W ln -s ../../main/f MK/sub/"      deny "$R2" a1 "$W_SIB" "ln -s ../../main/f $MK/sub/"
mk "ln7 cwd=W cd o2/d && ln -s -t MK ../main/f" deny "$R2" a1 "$W_SIB" "cd $tmp/o2/d && ln -s -t $MK ../main/f"
mk "ln8 cwd=W opaque: ln -s ..\\/main/f MK/l2" deny "$R2" a1 "$W_SIB" "cd $tmp/o2/d && ln -s ..\\/main/f $MK/l2"
mk "ln9 cwd=W echo > MK/sub/lf1 (two hops)"    deny "$R2" a1 "$W_SIB" "echo pwn > $MK/sub/lf1"
mk "ln10 cwd=W cd o2/d && ln -s .. && echo (no agent)" deny "$R1" "" "$W_SIB" "cd $tmp/o2/d && ln -s ../main/f $MK/l2 && echo pwn > $MK/l2"
mk "ln11 cwd=W ln -s sub/a MK/l2"              allow "" a1 "$W_SIB" "ln -s sub/a $MK/l2"
mk "ln12 cwd=W cd MK && ln -s ../opt-marker/sub l3" allow "" a1 "$W_SIB" "cd $MK && ln -s ../opt-marker/sub l3"
mk "ln13 cwd=W echo > MK/ls/a (dir link within)" allow "" a1 "$W_SIB" "echo x > $MK/ls/a"
mk "ln14 cwd=W ln -s ../x MK/sub/l2 (in MK)"   allow "" a1 "$W_SIB" "ln -s ../x $MK/sub/l2"
check "ln15 Write agent cwd=W MK/lf (link into M)" deny "$R2" "$(write_json a1 "$W_SIB" "$MK/lf")"
# rm, mv, ln's names and chmod -h act on the link itself: not followed.
mk "ln16 cwd=W rm MK/lf"                       allow "" a1 "$W_SIB" "rm $MK/lf"
mk "ln17 cwd=W rm W/lw (own link into M)"      allow "" a1 "$W_SIB" "rm $W_SIB/lw"
mk "ln18 cwd=W mv W/lw W/lw2; unlink W/lw"     allow "" a1 "$W_SIB" "mv $W_SIB/lw $W_SIB/lw2; unlink $W_SIB/lw"
mk "ln19 cwd=W chmod -h 600 W/lw"              allow "" a1 "$W_SIB" "chmod -h 600 $W_SIB/lw"
mk "ln20 cwd=W ln -sf x W/lw"                  allow "" a1 "$W_SIB" "ln -sf x $W_SIB/lw"
# Writers go through a link: redirect, tee, cp's destination, chmod without -h, Write.
mk "ln21 cwd=W echo > W/lw"                    deny "$R2" a1 "$W_SIB" "echo pwn > $W_SIB/lw"
mk "ln22 cwd=W echo | tee W/lw"                deny "$R2" a1 "$W_SIB" "echo pwn | tee $W_SIB/lw"
mk "ln23 cwd=W cp W/qf W/lw"                   deny "$R2" a1 "$W_SIB" "cp $W_SIB/qf $W_SIB/lw"
mk "ln24 cwd=W chmod 600 W/lw"                 deny "$R2" a1 "$W_SIB" "chmod 600 $W_SIB/lw"
check "ln25 Write agent cwd=W W/lw"            deny "$R2" "$(write_json a1 "$W_SIB" "$W_SIB/lw")"
# Chains: 10, 31 and 33 links; Write through 10; the legit chain in W; 260 links.
mk "ln26 cwd=W echo > MK/c1 (10 links)"        deny "$R2" a1 "$W_SIB" "echo pwn > $MK/c1"
check "ln27 Write agent cwd=W MK/c1 (10 links)" deny "$R2" "$(write_json a1 "$W_SIB" "$MK/c1")"
mk "ln28 cwd=W echo > MK/hc/h1 (31 links)"     deny "$R2" a1 "$W_SIB" "echo pwn > $MK/hc/h1"
mk "ln29 cwd=W echo > MK/hc/k1 (33 links)"     deny "$R2" a1 "$W_SIB" "echo pwn > $MK/hc/k1"
mk "ln30 cwd=W echo > W/q1 (legit chain)"      allow "" a1 "$W_SIB" "echo x > $W_SIB/q1"
mk "ln31 cwd=W echo > MK/lf (dangling into M)" deny "$R2" a1 "$W_SIB" "echo x > $MK/lf"
c="touch"; for i in $(seq 1 260); do c="$c $tmp/many2/l$i"; done
check "ln32 cwd=W touch 260 links (too many)"  deny "長すぎて" "$(bash_json a1 "$W_SIB" "$c")"
# A glob is never expanded: a globbed path gets no opt-out, so it is judged as if MK and
# OF were not exempt. W and dirs outside any repo keep HEAD's verdicts.
mk "gl1 cwd=W echo > MK/l?"                    deny "$R2" a1 "$W_SIB" "echo pwn > $MK/l?"
mk "gl2 cwd=W echo > MK/[l]f"                  deny "$R2" a1 "$W_SIB" "echo pwn > $MK/[l]f"
mk "gl3 cwd=W echo | tee MK/l?"                deny "$R2" a1 "$W_SIB" "echo pwn | tee $MK/l?"
mk "gl4 cwd=W cp out/q/lf MK/l?"               deny "$R2" a1 "$W_SIB" "cp $tmp/out/q/lf $MK/l?"
mk "gl5 cwd=W cd MK && echo > l?"              deny "$R2" a1 "$W_SIB" "cd $MK && echo pwn > l?"
check "gl6 cwd=W echo > OF/l? (listed)"        deny "$R2" "$(bash_json a1 "$W_SIB" "echo pwn > $OF/l?")"
mk "gl7 cwd=W echo > W/l? (own link, known hole as on HEAD)" allow "" a1 "$W_SIB" "echo pwn > $W_SIB/l?"
mk "gl8 cwd=W touch MK/g/l*/vendor"            deny "$R2" a1 "$W_SIB" "touch $MK/g/l*/vendor"
mk "gl9 cwd=W rm -rf MK/g/l*/vendor"           deny "$R2" a1 "$W_SIB" "rm -rf $MK/g/l*/vendor"
mk "gl10 cwd=W echo > W/q? (legit chain)"      allow "" a1 "$W_SIB" "echo x > $W_SIB/q?"
mk "gl11 cwd=W rm MK/sub/l? (no opt-out)"      deny "$R2" a1 "$W_SIB" "rm $MK/sub/l?"
mk "gl12 cwd=W echo > MK/n?ne (no opt-out)"    deny "$R2" a1 "$W_SIB" "echo x > $MK/n?ne"
mk "gl13 cwd=W echo > W/*.log"                 allow "" a1 "$W_SIB" "echo x > $W_SIB/*.log"
mk "gl14 cwd=W touch out/big/*/*/* (no repo)"  allow "" a1 "$W_SIB" "touch $tmp/out/big/*/*/*"
mk "gl15 cwd=W echo > MK/a~ (~ past start)"    deny "$R2" a1 "$W_SIB" "echo x > $MK/a~"
mk "gl16 cwd=W echo > MK/a (literal)"          allow "" a1 "$W_SIB" "echo x > $MK/a"
# The shell's locale: zé is one character in UTF-8, so z? and z[!x] match it in zsh.
mk "gl17 cwd=W echo > MK/z?"                   deny "$R2" a1 "$W_SIB" "echo pwn > $MK/z?"
mk "gl18 cwd=W echo > MK/z[!x]"                deny "$R2" a1 "$W_SIB" "echo pwn > $MK/z[!x]"
mk "gl19 cwd=W tee MK/z?"                      deny "$R2" a1 "$W_SIB" "echo pwn | tee $MK/z?"
mk "gl20 cwd=W cp out/q/lf MK/z?"              deny "$R2" a1 "$W_SIB" "cp $tmp/out/q/lf $MK/z?"
# zsh patterns: ** (kept in the word), and (a|b), <-> , <1-9> (split by the lexer: NXC).
mk "gl21 cwd=W echo > MK/**/lf"                deny "$R2" a1 "$W_SIB" "echo pwn > $MK/**/lf"
mk "gl22 cwd=W echo > MK/l(f|x)"               deny "$R2" a1 "$W_SIB" "echo pwn > $MK/l(f|x)"
mk "gl23 cwd=W echo > MK/(lf|zz)"              deny "$R2" a1 "$W_SIB" "echo pwn > $MK/(lf|zz)"
mk "gl24 cwd=W echo > MK/l<->"                 deny "$R2" a1 "$W_SIB" "echo pwn > $MK/l<->"
mk "gl25 cwd=W echo > MK/l<1-9>"               deny "$R2" a1 "$W_SIB" "echo pwn > $MK/l<1-9>"
mk "gl26 cwd=W tee MK/l(f|x)"                  deny "$R2" a1 "$W_SIB" "echo pwn | tee $MK/l(f|x)"
mk "gl27 cwd=W cp out/q/lf MK/l<->"            deny "$R2" a1 "$W_SIB" "cp $tmp/out/q/lf $MK/l<->"
mk "gl28 cwd=W cd MK && echo > l(f|x)"         deny "$R2" a1 "$W_SIB" "cd $MK && echo pwn > l(f|x)"
mk "gl29 cwd=W cd MK && echo > **/lf"          deny "$R2" a1 "$W_SIB" "cd $MK && echo pwn > **/lf"
mk "gl32 cwd=W cd MK && echo > (lf|x)"         deny "$R2" a1 "$W_SIB" "cd $MK && echo pwn > (lf|x)"
mk "gl33 cwd=W cd MK && tee (lf|x)"            deny "$R2" a1 "$W_SIB" "cd $MK && echo pwn | tee (lf|x)"
mk "gl34 cwd=W true && (echo x > MK/a)"        allow "" a1 "$W_SIB" "true && (echo x > $MK/a)"
# Not zsh patterns: \$( ), a leading subshell, an array.
mk "gl30 cwd=W echo \$(date) > MK/a"           allow "" a1 "$W_SIB" "echo \$(date) > $MK/a"
mk "gl31 cwd=W (echo x > MK/a)"                allow "" a1 "$W_SIB" "(echo x > $MK/a)"
# cp into a directory writes <dir>/<name>, through a link of that name.
mk "cd1 cwd=W cp out/q/lf MK/"                 deny "$R2" a1 "$W_SIB" "cp $tmp/out/q/lf $MK/"
mk "cd2 cwd=W cp out/q/lf MK"                  deny "$R2" a1 "$W_SIB" "cp $tmp/out/q/lf $MK"
mk "cd3 cwd=W cd MK && cp out/q/lf ."          deny "$R2" a1 "$W_SIB" "cd $MK && cp $tmp/out/q/lf ."
mk "cd4 cwd=W cp out/q/* MK/ (glob source)"    deny "$R2" a1 "$W_SIB" "cp $tmp/out/q/* $MK/"
mk "cd5 cwd=W cp out/q/ok W/ (W has no ok)"    allow "" a1 "$W_SIB" "cp $tmp/out/q/ok $W_SIB/"
mk "cd6 cwd=W cp out/q/lf out/q/ok MK/sub/"    allow "" a1 "$W_SIB" "cp $tmp/out/q/lf $tmp/out/q/ok $MK/sub/"
mk "cd7 cwd=W mv out/q/lf MK/sub/lf0 (replaces link)" allow "" a1 "$W_SIB" "mv $tmp/out/q/lf $MK/sub/lf0"
mk "cd8 cwd=W cp -R out/q/lf MK/ (no write through)" allow "" a1 "$W_SIB" "cp -R $tmp/out/q/lf $MK/"
# A hard link is made to what a source link points to.
mk "hl1 cwd=W ln out/zz W/h"                   deny "$R2" a1 "$W_SIB" "ln $tmp/out/zz $W_SIB/h"
mk "hl2 cwd=W ln MK/lf W/h"                    deny "$R2" a1 "$W_SIB" "ln $MK/lf $W_SIB/h"
mk "hl3 cwd=W ln MK/lf (into the cwd)"         deny "$R2" a1 "$W_SIB" "ln $MK/lf"
mk "hl4 cwd=W ln -s MK/lf W/h (symbolic)"      allow "" a1 "$W_SIB" "ln -s $MK/lf $W_SIB/h"
mk "hl5 cwd=W ln W/qf W/h (legit)"             allow "" a1 "$W_SIB" "ln $W_SIB/qf $W_SIB/h"
mk "hl6 cwd=W ln W/q1 W/h (legit chain)"       allow "" a1 "$W_SIB" "ln $W_SIB/q1 $W_SIB/h"
# readlink -f gives up on a loop and hands back a link: refused. A dangling last hop
# within W (readlink exits 1 there too) is let through.
mk "rl1 cwd=W echo > MK/g/la (loop)"           deny "$U1" a1 "$W_SIB" "echo pwn > $MK/g/la"
check "rl2 cwd=M echo > MK/g/la (loop, no agent)" deny "$R1" "$(bash_json "" "$M" "echo pwn > $MK/g/la")"
mk "rl3 cwd=W echo > W/ldang (dangling in W)"  allow "" a1 "$W_SIB" "echo x > $W_SIB/ldang"
# A marker made through a path the hook does not follow. In a repo the variable leaves
# the target unresolved (R2U / R1); from outside every repo it passes, as on HEAD.
mk "mk34 cwd=W f=..; touch .claude/\${f}.."    deny "$U1" a1 "$W_SIB" "f=no-iso; touch .claude/\${f}lation"
mk "mk35 cwd=M f=..; touch M/.claude/\${f}.. (no agent)" deny "$R1" "" "$M" "f=no-iso; touch $M/.claude/\${f}lation"
mk "mk36 cwd=out f=..; touch M/.claude/\${f}.. (known hole)" allow "" a1 "$tmp/out" "f=no-iso; touch $M/.claude/\${f}lation"
# APFS ignores case, so SELF does too: any letter case of either name, Bash and Edit/Write.
SELF=ユーザーだけが編集
edit_json() {  # <agent|""> <cwd> <file_path>
  jq -n --arg a "$1" --arg c "$2" --arg p "$3" \
    '{tool_name:"Edit",cwd:$c,tool_input:{file_path:$p,old_string:"a",new_string:"b"}} + (if $a == "" then {} else {agent_id:$a} end)'
}
check "sc1 cwd=W touch W/.claude/NO-ISOLATION"   deny "$SELF" "$(bash_json a1 "$W_SIB" "mkdir -p $W_SIB/.claude && touch $W_SIB/.claude/NO-ISOLATION")"
check "sc2 cwd=W touch .claude/No-Isolation"     deny "$SELF" "$(bash_json a1 "$W_SIB" "touch .claude/No-Isolation")"
check "sc3 cwd=M touch M/.Claude/NO-ISOLATION"   deny "$SELF" "$(bash_json a1 "$M" "touch $M/.Claude/NO-ISOLATION")"
check "sc4 cwd=M touch .claude/No-Isolation (no agent)" deny "$SELF" "$(bash_json "" "$M" "touch .claude/No-Isolation")"
check "sc5 Write agent W/.claude/NO-ISOLATION"   deny "$SELF" "$(write_json a1 "$W_SIB" "$W_SIB/.claude/NO-ISOLATION")"
check "sc6 Edit agent W/.CLAUDE/No-Isolation"    deny "$SELF" "$(edit_json a1 "$W_SIB" "$W_SIB/.CLAUDE/No-Isolation")"
check "sc7 Write cwd=M M/.claude/No-Isolation (no agent)" deny "$SELF" "$(write_json "" "$M" "$M/.claude/No-Isolation")"
check "sc8 Edit cwd=M .claude/NO-ISOLATION (no agent)" deny "$SELF" "$(edit_json "" "$M" ".claude/NO-ISOLATION")"
check "sc9 Write ~/.claude/hooks/No-Isolation-Repos" deny "$SELF" "$(write_json a1 "$W_SIB" "$HOME/.claude/hooks/No-Isolation-Repos")"
check "sc10 echo >> ~/.claude/hooks/NO-ISOLATION-REPOS" deny "$SELF" "$(bash_json a1 "$tmp/out" "echo x >> ~/.claude/hooks/NO-ISOLATION-REPOS")"
check "sc11 cat .claude/NO-ISOLATION (read)"     allow ""  "$(bash_json a1 "$W_SIB" "cat .claude/NO-ISOLATION")"
# A marker counts only as a regular file in a real .claude dir, neither a symlink.
mk "sl1 cwd=W echo > sl1/a (.claude symlinked out)" deny "$R2" a1 "$W_SIB" "echo x > $tmp/sl1/a"
mk "sl2 cwd=W echo > sl2/a (marker symlinked out)" deny "$R2" a1 "$W_SIB" "echo x > $tmp/sl2/a"
check "sl3 cwd=sl1 touch M/a"                    deny "$R2" "$(bash_json a1 "$tmp/sl1" "touch $M/a")"
check "sl4 cwd=sl2 touch M/a"                    deny "$R2" "$(bash_json a1 "$tmp/sl2" "touch $M/a")"
check "sl5 cwd=sl1 git commit (no agent)"        deny "$R1" "$(bash_json "" "$tmp/sl1" "git commit -m x")"
check "sl6 cwd=sl2 git commit (no agent)"        deny "$R1" "$(bash_json "" "$tmp/sl2" "git commit -m x")"
check "sl7 Write cwd=sl1 sl1/a (no agent)"       deny "$R1" "$(write_json "" "$tmp/sl1" "$tmp/sl1/a")"
# The .claude dir holding a main checkout's marker is the user's: removing, moving or
# copying it is SELF. Other files under it are judged as before.
mk "sd1 cwd=W rm -rf MK/.claude"                 deny "$SELF" a1 "$W_SIB" "rm -rf $MK/.claude"
mk "sd2 cwd=W mv MK/.claude MK/c2"               deny "$SELF" a1 "$W_SIB" "mv $MK/.claude $MK/c2"
mk "sd3 cwd=M mv MK/c2 MK/.claude (back)"        deny "$SELF" a1 "$M" "mv $MK/c2 $MK/.claude"
mk "sd4 cwd=W rm -rf MK/.CLAUDE"                 deny "$SELF" a1 "$W_SIB" "rm -rf $MK/.CLAUDE"
mk "sd5 cwd=W cp -r MK/.claude ."                deny "$SELF" a1 "$W_SIB" "cp -r $MK/.claude ."
mk "sd6 cwd=W rm -rf MK/.claude/*"               deny "$SELF" a1 "$W_SIB" "rm -rf $MK/.claude/*"
mk "sd7 cwd=out x=\$y; rm -rf MK/.claude (opaque)" deny "$SELF" a1 "$tmp/out" "x=\$y; rm -rf $MK/.claude"
mk "sd8 cwd=W echo > MK/.claude/settings.json"   allow "" a1 "$W_SIB" "echo x > $MK/.claude/settings.json"
mk "sd9 cwd=W rm MK/.claude/settings.json"       allow "" a1 "$W_SIB" "rm $MK/.claude/settings.json"
check "sd10 Edit agent cwd=W MK/.claude/settings.json" allow "" "$(edit_json a1 "$W_SIB" "$MK/.claude/settings.json")"
check "sd11 cwd=W rm -rf M/.claude (unmarked: R2)" deny "$R2" "$(bash_json a1 "$W_SIB" "rm -rf $M/.claude")"
check "sd12 cwd=W rm -rf OPT-MARKER (other case)" deny "$R2" "$(bash_json a1 "$W_SIB" "rm -rf $tmp/OPT-MARKER")"
# Copying the marker into a linked worktree writes only there, so it passes; the copy
# opts nothing out, since a marker in a worktree alone does not count (mk33, mk31).
check "sd13 cwd=W tar -C MK -c .claude | tar -x" allow "" "$(bash_json a1 "$W_SIB" "tar -C $MK -cf - .claude | tar -xf - -C $W_SIB")"
check "sd14 cwd=W cp -r MK/. W/"                 allow ""  "$(bash_json a1 "$W_SIB" "cp -r $MK/. $W_SIB/")"
# Rule 1 (no agent) denies everything the original did, cwd-relative, cd ignored.
check "r1a cwd=M git -C /tmp commit (no agent)" deny "$R1" "$(bash_json "" "$M" "git -C /tmp commit -m x")"
check "r1b cwd=M cd /tmp && rm a (no agent)" deny "$R1" "$(bash_json "" "$M" "cd /tmp && rm a")"
check "r1c cwd=M make --dry-run (no agent)"  deny "$R1" "$(bash_json "" "$M" "make --dry-run")"
check "r1d Write cwd=M /tmp/new/x (no agent)" deny "$R1" "$(write_json "" "$M" "/tmp/nonexistent-$$/x")"
check "r1e cwd=M rm /tmp/f (no agent)"       allow ""  "$(bash_json "" "$M" "rm /tmp/f")"

# Over 16384 chars a command that mutates anything at all is denied as too long
# to judge; one that does not is allowed. (These 120-pair chains pass 16384.)
TL=長すぎて
long=""; for i in $(seq 1 120); do long="$long git -C $W_SIB add f$i && echo x > $W_SIB/g$i &&"; done
check "l1 cwd=M 241 segments, all in W"      deny "$TL" "$(bash_json a1 "$M" "$long true")"
# Conservative deny by design: over the cap nothing is tracked, even from W.
check "l2 cwd=W 241 segments, all in W"      deny "$TL" "$(bash_json a1 "$W_SIB" "$long true")"
check "l3 cwd=W 241 segments, one into M"    deny "$TL" "$(bash_json a1 "$W_SIB" "$long echo x > $M/a")"
ls250=""; for i in $(seq 1 250); do ls250="$ls250 ls a$i;"; done
check "l4 cwd=M 250 read-only segments"      allow ""  "$(bash_json a1 "$M" "$ls250")"
# Should-fix 1: padding past the cap must not reopen W -> M.
pad=$(for i in $(seq 1 200); do printf 'true; '; done)
xs=$(head -c 16400 /dev/zero | tr '\0' x)
check "c1 cwd=W 200x true; cd ../main && commit" deny "$R2" "$(bash_json a1 "$W_SIB" "$pad cd ../main && git commit -m x")"
check "c2 cwd=W cd ../main && commit # 16K"  deny "$TL" "$(bash_json a1 "$W_SIB" "cd ../main && git commit -m x # $xs")"
check "c3 cwd=W git -C ../main commit # 16K" deny "$TL" "$(bash_json a1 "$W_SIB" "git -C ../main commit -m x # $xs")"
check "c4 cwd=W git -C M commit # 16K"       deny "$TL" "$(bash_json a1 "$W_SIB" "git -C $M commit -m x # $xs")"
# A writer early in a long multi-line command: the over-cap scan must read it all.
echos=$(for i in $(seq 1 8000); do printf 'echo %d\n' $i; done)
check "c5 cwd=M rm -rf M + 8000 echo lines (no agent)" deny "$TL" "$(bash_json "" "$M" "rm -rf $M${NL}$echos")"
check "c6 cwd=W rm -rf M + 8000 echo lines"  deny "$TL" "$(bash_json a1 "$W_SIB" "rm -rf $M${NL}$echos")"

# Should-fix 8: a dir the Write tool would create is judged by its nearest
# existing parent, not by the cwd.
check "w1 Write agent cwd=W M/new/dir/f"     deny "$R2" "$(write_json a1 "$W_SIB" "$M/new/dir/f")"
check "w2 Write agent cwd=M W/new/dir/f"     allow ""  "$(write_json a1 "$M" "$W_SIB/new/dir/f")"

# Outside any work tree the cwd says nothing; only paths into a main checkout are refused.
check "n1 cwd=/tmp git -C M commit"           deny "$R2" "$(bash_json a1 /tmp "git -C $M commit -m x")"
check "n2 cwd=/tmp cd M && commit (no agent)" deny "$R1" "$(bash_json "" /tmp "cd $M && git commit -m x")"
check "n3 cwd=/ echo x > M/a"                 deny "$R2" "$(bash_json a1 / "echo x > $M/a")"
check "n4 cwd=/tmp rm -rf /tmp/x (no agent)"  allow ""  "$(bash_json "" /tmp "rm -rf /tmp/x")"
check "n5 cwd=/tmp cd W && commit"            allow ""  "$(bash_json a1 /tmp "cd $W_SIB && git commit -m x")"
check "n6 cwd=W env -C M git commit"          deny "$R2" "$(bash_json a1 "$W_SIB" "env -C $M git commit -m x")"

# Quoted words: a quoted path with a space stays one word, and a quoted
# redirect target is still a target.
mkdir -p "$W_SIB/x y"
check "q1 cwd=W git -C \"W/x y/../../main\" commit" deny "$R2" "$(bash_json a1 "$W_SIB" "git -C \"$W_SIB/x y/../../main\" commit -m x")"
check "q2 cwd=M cd W && echo > \"../main/a\""  deny "$R2" "$(bash_json a1 "$M" "cd $W_SIB && echo x > \"../main/a\"")"
check "q3 cwd=W git -C \"W/x y\" commit"      allow ""  "$(bash_json a1 "$W_SIB" "git -C \"$W_SIB/x y\" commit -m x")"
check "q4 cwd=W echo \"a > b\" && git status" allow ""  "$(bash_json a1 "$W_SIB" "echo \"a > b\" && git status")"

# Round 3. W is the sibling worktree, every case runs as an agent unless noted.
W=$W_SIB
U=確認できません
SELF=ユーザーだけが編集
# M2: a redirect target ends at the operator after it.
check "e1 echo \$y >/dev/null; rm -rf M/a"        deny "$R2" "$(bash_json a1 "$W" "echo \$y >/dev/null; rm -rf $M/a")"
check "e2 cd M >/dev/null; git commit"           deny "$R2" "$(bash_json a1 "$W" "cd $M >/dev/null; git commit -m x")"
check "e3 echo \$HOME >/dev/null; git -C M commit" deny "$R2" "$(bash_json a1 "$W" "echo \$HOME >/dev/null; git -C $M commit -m x")"
check "e4 echo \$y </dev/null|rm -rf M/a"         deny "$R2" "$(bash_json a1 "$W" "echo \$y </dev/null|rm -rf $M/a")"
check "e5 echo \$y >/dev/null&&rm -rf M/a"        deny "$R2" "$(bash_json a1 "$W" "echo \$y >/dev/null&&rm -rf $M/a")"
# M4: GIT_* set by export/declare/env, or read from config the hook cannot see.
check "g1 export GIT_DIR=M/.git && commit"       deny "$R2" "$(bash_json a1 "$W" "export GIT_DIR=$M/.git && git commit -m x")"
check "g2 export GIT_WORK_TREE=M; checkout"      deny "$R2" "$(bash_json a1 "$W" "export GIT_WORK_TREE=$M; git checkout -- .")"
check "g3 declare -x GIT_DIR=M/.git; commit"     deny "$R2" "$(bash_json a1 "$W" "declare -x GIT_DIR=$M/.git; git commit -m x")"
check "g4 env GIT_DIR=M/.git git commit"         deny "$R2" "$(bash_json a1 "$W" "env GIT_DIR=$M/.git git commit -m x")"
check "g5 env -u X GIT_WORK_TREE=M checkout"     deny "$R2" "$(bash_json a1 "$W" "env -u X GIT_WORK_TREE=$M git checkout -- .")"
check "g6 git --config-env=core.worktree=X"      deny "$U"  "$(bash_json a1 "$W" "X=$M git --config-env=core.worktree=X checkout -- .")"
check "g7 GIT_CONFIG_PARAMETERS core.worktree"   deny "$U"  "$(bash_json a1 "$W" "GIT_CONFIG_PARAMETERS=\"'core.worktree'='$M'\" git checkout -- .")"
# M5: file_path is joined with the cwd and normalized before its parent is looked up.
check "w3 Write W/new/../../main/a"              deny "$R2" "$(write_json a1 "$W" "$W/new/../../main/a")"
check "w4 Write ../main/a (relative)"            deny "$R2" "$(write_json a1 "$W" "../main/a")"
check "w5 Write W/new/dir/f"                     allow ""  "$(write_json a1 "$W" "$W/new/dir/f")"
check "w6 Write sub/f (relative)"                allow ""  "$(write_json a1 "$W" "sub/f")"
# A verb from a variable or $(...), wrappers, attached option values.
check "v1 cmd=rm; \$cmd -rf M/a"                  deny "$R2" "$(bash_json a1 "$W" "cmd=rm; \$cmd -rf $M/a")"
check "v2 \$(echo rm) -rf M/a"                    deny "$R2" "$(bash_json a1 "$W" "\$(echo rm) -rf $M/a")"
check "v8 cwd=M cmd=rm; \$cmd -rf a"             deny "$R2" "$(bash_json a1 "$M" "cmd=rm; \$cmd -rf a")"
check "g8 GIT_CONFIG_NOSYSTEM=1 git commit"      allow ""  "$(bash_json a1 "$W" "GIT_CONFIG_NOSYSTEM=1 git commit -m x")"
check "so6 Write W/.claude/x/../no-isolation"    deny "$SELF" "$(write_json a1 "$W" "$W/.claude/x/../no-isolation")"
for wr in "arch -arm64" "ionice -c3" "flock /tmp/l" setsid "script -q /dev/null" "gtimeout 5"; do
  check "v3 $wr rm -rf M/a"                      deny "$R2" "$(bash_json a1 "$W" "$wr rm -rf $M/a")"
done
check "v4 npx rimraf M/a"                        deny "$R2" "$(bash_json a1 "$W" "npx rimraf $M/a")"
check "v5 curl -oM/a"                            deny "$R2" "$(bash_json a1 "$W" "curl -o$M/a http://x")"
check "v6 wget -OM/a"                            deny "$R2" "$(bash_json a1 "$W" "wget -O$M/a http://x")"
check "v7 npx tsc (not a writer)"                allow ""  "$(bash_json a1 "$W" "npx tsc --noEmit")"
# git subcommands that write where an argument points.
check "x1 git clone . M/y"                       deny "$R2" "$(bash_json a1 "$W" "git clone . $M/y")"
check "x2 git init M/x"                          deny "$R2" "$(bash_json a1 "$W" "git init $M/x")"
check "x3 git archive -o M/a.tar"                deny "$R2" "$(bash_json a1 "$W" "git archive -o $M/a.tar HEAD")"
check "x4 git format-patch -o M"                 deny "$R2" "$(bash_json a1 "$W" "git format-patch -o $M HEAD~1")"
check "x5 git diff --output=M/a"                 deny "$R2" "$(bash_json a1 "$W" "git diff --output=$M/a")"
check "x6 git diff --output=/tmp/a"              allow ""  "$(bash_json a1 "$W" "git diff --output=/tmp/a")"
check "x7 git -C M log --oneline"                allow ""  "$(bash_json a1 "$W" "git -C $M log --oneline")"
# Self opt-out: the markers are the user's, whoever asks and from wherever.
check "so1 touch .claude/no-isolation"           deny "$SELF" "$(bash_json a1 "$W" "mkdir -p .claude && touch .claude/no-isolation")"
check "so2 Write W/.claude/no-isolation"         deny "$SELF" "$(write_json a1 "$W" "$W/.claude/no-isolation")"
check "so3 echo >> no-isolation-repos (no agent)" deny "$SELF" "$(bash_json "" /tmp "echo $W >> ~/.claude/hooks/no-isolation-repos")"
check "so4 Write no-isolation-repos (no agent)"  deny "$SELF" "$(write_json "" /tmp "$HOME/.claude/hooks/no-isolation-repos")"
check "so5 cat no-isolation-repos"               allow ""  "$(bash_json a1 "$W" "cat ~/.claude/hooks/no-isolation-repos")"
# Known limits, kept on purpose: an opted-out cwd lets every command through, so from an
# opted-out repo (or a worktree of one) a write into M passes; a linked worktree nested in M is not main;
# git update-ref / config core.hooksPath / config --worktree core.worktree run from W
# are not judged; a symlink made in the same command and used as a dir (ln -s .. l &&
# rm -rf l/main), a hard link made by an unlisted writer, and writers not listed (gzip, sort -o, ditto, prettier --write, python3 -c) are not followed.
check "k1 cwd=opted-out repo rm -rf M/a"         allow ""  "$(bash_json a1 "$tmp/opt-future" "rm -rf $M/a")"
# Without jq the hook still denies, by printf.
mkdir -p "$tmp/nojq"
for b in cat git sed tr grep sort dirname date wc head; do ln -s "$(command -v $b)" "$tmp/nojq/$b"; done
out=$(bash_json a1 "$W" "ls" | env PATH="$tmp/nojq" "$BASH" "$hook" 2>/dev/null)
case $out in *'"permissionDecision":"deny"'*) pass=$((pass+1)); echo "PASS  j1 no jq: deny";;
  *) fail=$((fail+1)); echo "FAIL  j1 no jq: deny (got ${out:0:80})";; esac
# Input the hook cannot read is refused, not waved through.
out=$(bash_json a1 "$W" "ls" | env -u HOME "$BASH" "$hook" 2>/dev/null)
case $out in *'"permissionDecision":"deny"'*HOME*) pass=$((pass+1)); echo "PASS  j2 no HOME: deny";;
  *) fail=$((fail+1)); echo "FAIL  j2 no HOME: deny (got ${out:0:80})";; esac
for j in '{}' 'not json' '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":["rm","x"]}}'; do
  check "j3 malformed: $j"                       deny ""   "$j"
done
mkdir -p "$tmp/out"
check "w7 Write no agent cwd=outside out/new/../../main/a" deny "$R1" "$(write_json "" "$tmp/out" "$tmp/out/new/../../main/a")"

# Speed. A hook that hits Claude Code's timeout (10s) does not deny, so every
# input must be judged well inside it. timed <label> <allow|deny|either> <json>
# requires the verdict and a wall time under 2 s.
unset ENFORCE_BUDGET_SECS
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
timed() {
  local s e out el ok=0
  s=$(now); out=$(printf '%s' "$3" | "$BASH" "$hook" 2>/dev/null); e=$(now)
  el=$(echo "$e - $s" | bc)
  case $2:$out in either:*|allow:|deny:*permissionDecision*deny*) ok=1;; esac
  if [ "$ok" = 1 ] && [ "$(echo "$el < 2" | bc)" = 1 ]; then pass=$((pass+1)); printf 'PASS  %s: %ss\n' "$1" "$el"
  else fail=$((fail+1)); printf 'FAIL  %s: %ss, want %s, out=%.60s\n' "$1" "$el" "$2" "$out"; fi
}
many="rm -rf"; for i in $(seq 1 400); do mkdir -p "$W_SIB/d$i"; done
# As many path args as fit under the 16K cap (about 1600) in 400 directories:
# more distinct directories than the hook resolves, so it denies as too long.
i=0; while [ ${#many} -lt 15900 ]; do i=$((i+1)); many="$many d$((i%400+1))/x$i"; done
check "b1 $i path args in 400 dirs (conservative deny)" deny "$TL" "$(bash_json a1 "$W_SIB" "$many")"
timed "b2 cwd=M cd W && rm ~1600 path args" either "$(bash_json a1 "$M" "cd $W_SIB && $many")"
# Paths into a listed repo near the cap, each judged for the list and its holders.
for i in $(seq 1 60); do mkdir -p "$OF/d$i"; done
c="cd $OF"; i=0; while [ ${#c} -lt 15900 ]; do i=$((i+1)); c="$c && touch d$((i%60+1))/x$i"; done
timed "b3 cwd=M cd opt-future && touch x ~1000 in 60 dirs" allow "$(bash_json a1 "$M" "$c")"
c="rm -rf"; i=0; while [ ${#c} -lt 15900 ]; do i=$((i+1)); c="$c $OF/d$((i%60+1))/x$i"; done
timed "b4 cwd=M rm -rf ~400 paths in opt-future" allow "$(bash_json a1 "$M" "$c")"
# The same into a marked repo, with no list file at all.
for i in $(seq 1 60); do mkdir -p "$MK/d$i"; done
HOME=$tmp/home2
c="cd $MK"; i=0; while [ ${#c} -lt 15900 ]; do i=$((i+1)); c="$c && touch d$((i%60+1))/x$i"; done
timed "b5 [home2] cwd=M cd opt-marker && touch x ~1000 in 60 dirs" allow "$(bash_json a1 "$M" "$c")"
c="rm -rf"; i=0; while [ ${#c} -lt 15900 ]; do i=$((i+1)); c="$c $MK/d$((i%60+1))/x$i"; done
timed "b6 [home2] cwd=M rm -rf ~400 paths in opt-marker" allow "$(bash_json a1 "$M" "$c")"
# Relative names keep these under the 16K cap, so the link handling is what is timed.
c="echo pwn > $M/f"; for i in $(seq 1 200); do c="$c; touch q1"; done
timed "b7 [home2] cwd=W echo > M/f; touch W/q1 (9 links) x200" deny "$(bash_json a1 "$W_SIB" "$c")"
c="touch"; for i in $(seq 1 200); do c="$c q$((i%9+1))"; done
timed "b8 [home2] cwd=W touch q1..q9 x200 (legit chain)" allow "$(bash_json a1 "$W_SIB" "$c")"
# A quoted deep pattern is not expanded (round 6 took 11-67 s on one): judged at once.
timed "b9 [home2] cwd=W touch '/*/*/*/*/*/*/*/zz'; echo > MK/lf" deny "$(bash_json a1 "$W_SIB" "touch '/*/*/*/*/*/*/*/zz'; echo pwn > $MK0/lf")"
HOME=$tmp/home
# Round 2, B: cd - plus a dozen cd targets, then eval and a long cd . run.
for i in $(seq 1 14); do mkdir -p "$tmp/d$i"; done
c="cd -"; for i in $(seq 1 14); do c="$c; cd $tmp/d$i"; done; c="$c; eval :"
tail="; cd $M && git commit -m x"
while [ $(( ${#c} + ${#tail} )) -lt 16370 ]; do c="$c cd ."; done
timed "rB cd -; 14 cds; eval : cd . x3000; cd M && commit" deny "$(bash_json a1 "$M" "$c$tail")"
timed "rB2 same shape from cwd=W" deny "$(bash_json a1 "$W_SIB" "$c$tail")"
# Round 2, C: 8000 double quotes, then a commit.
timed "rC 8000 quotes; git commit" deny "$(bash_json a1 "$M" "$(head -c 8000 /dev/zero | tr '\0' '"'); git commit -m x")"
timed "rC2 7999 quotes; git commit (unbalanced)" deny "$(bash_json a1 "$M" "$(head -c 7999 /dev/zero | tr '\0' '"'); git commit -m x")"
# Worst shapes under the caps: 199 mutating segments, one long word.
c="cd $W_SIB"; for i in $(seq 1 199); do c="$c; rm d$i/a d$i/b"; done
timed "p1 cd W; 199 x rm (64-dir cap)" either "$(bash_json a1 "$M" "$c")"
c=""; for i in $(seq 1 199); do c="$c rm /tmp/x$i;"; done
timed "p2 cwd=W 199 x rm /tmp" allow "$(bash_json a1 "$W_SIB" "$c")"
timed "p3 cwd=M one 16000-char word + commit" deny "$(bash_json a1 "$M" "git commit -m $(head -c 16000 /dev/zero | tr '\0' a)")"
# Round 3, M1: long but ordinary work in W is not refused for its separators.
lines() { for i in $(seq 1 $1); do printf 'line %d: some text | with pipe; and (parens) & stuff\n' $i; done; }
body=$(printf '## Summary\n\n| file | change | why |\n|---|---|---|\n'; for i in $(seq 1 25); do printf '| f%d.ts | edit (x) | y; z |\n' $i; done)
timed "a1 gh pr create --body heredoc, 25-row table" allow "$(bash_json a1 "$W" "gh pr create --title t --body \"\$(cat <<'EOF'$NL$body${NL}EOF$NL)\"")"
timed "a2 cat > notes.txt, 120-line heredoc" allow "$(bash_json a1 "$W" "cat > notes.txt <<'EOF'$NL$(lines 120)${NL}EOF")"
timed "a3 git commit -F -, 210-line heredoc" allow "$(bash_json a1 "$W" "git commit -F - <<'EOF'$NL$(lines 210)${NL}EOF")"
timed "a4 git commit -m with 60 lines, pipes" allow "$(bash_json a1 "$W" "git commit -m '$(lines 60)'")"
c="cd $W"; for i in $(seq 1 99); do c="$c && rm a$i"; done
timed "a5 cd W && rm a1 && ... rm a99" allow "$(bash_json a1 "$W" "$c")"
timed "a6 16000 open parens" either "$(bash_json a1 "$W" "$(head -c 16000 /dev/zero | tr '\0' '(')")"
c=""; for i in $(seq 1 3000); do c="${c}true;"; done
timed "a7 x=\$y; 3000 x true; rm M/a" deny "$(bash_json a1 "$W" "x=\$y; $c rm $M/a")"
# M3: quotes and backslashes do not hide a writer, under the cap or over it.
for c in "r''m -rf $M" "g''it -C $M commit -m x" "r\\m -rf $M"; do
  base="$c #"; ys=$(head -c $((16384-${#base})) /dev/zero | tr '\0' y)
  timed "m3 16384: $c" deny "$(bash_json a1 "$W" "$base$ys")"
  timed "m3 16385: $c" deny "$(bash_json a1 "$W" "${base}y$ys")"
done

# Quoted heredoc bodies are data: an allowlisted shape is judged without them. Each
# case runs from the main thread (cwd=M and cwd outside any repo) and from an agent in W.
O=$tmp/out
TAB=$'\t'
hd3() {  # <label> <allow|deny> <command>
  check "h $1 (no agent, cwd=M)"   "$2" "" "$(bash_json "" "$M" "$3")"
  check "h $1 (no agent, cwd=out)" "$2" "" "$(bash_json "" "$O" "$3")"
  check "h $1 (agent, cwd=W)"      "$2" "" "$(bash_json a1 "$W" "$3")"
}
hb="- Tak / Taksfc${NL}cp x y${NL}git commit -m x${NL}rm -rf /${NL}rm -rf $M"
hd3 "h1 cat > out <<'EOF' (/ cp git rm in body)" allow "cat > $O/pr.md <<'EOF'$NL$hb${NL}EOF"
hd3 "h2 cat <<'EOF' > out"               allow "cat <<'EOF' > $O/pr.md$NL$hb${NL}EOF"
hd3 "h3 cat > out <<\"EOF\""             allow "cat > $O/pr.md <<\"EOF\"$NL$hb${NL}EOF"
hd3 "h4 cat > out <<\\EOF"               allow "cat > $O/pr.md <<\\EOF$NL$hb${NL}EOF"
hd3 "h5 cat > out <<-'EOF' (tab EOF)"    allow "cat > $O/pr.md <<-'EOF'$NL$TAB$hb$NL${TAB}EOF"
hd3 "h6 two quoted heredocs"             allow "cat > $O/a <<'EOF'$NL$hb${NL}EOF${NL}cat >> $O/b <<'X'$NL$hb${NL}X"
hd3 "h7 tee -a out <<'EOF' >/dev/null"   allow "tee -a $O/a $O/b <<'EOF' >/dev/null$NL$hb${NL}EOF"
hd3 "h8 gh pr create --body \"\$(cat <<'EOF'\"" allow "gh pr create --title x --body \"\$(cat <<'EOF'$NL- a / b${NL}EOF$NL)\""
hd3 "h9 cat > out; gh pr edit --body-file" allow "cat > $O/pr.md <<'EOF'$NL- Tak / Taksfc${NL}EOF${NL}gh pr edit 669 --body-file $O/pr.md"
hd3 "h10 cd out && cat > out/f; ls && wc -l" allow "cd $O && cat > $O/f <<'EOF'$NL$hb${NL}EOF${NL}ls && wc -l $O/f"
# What the allowlist does not vouch for keeps the old reading, body and all.
X="rm -rf $M/x"
hd3 "d1 <<EOF with \$(rm -rf M)"         deny "cat > $O/a <<EOF$NL\$(rm -rf $M)${NL}EOF"
hd3 "d2 bash <<'EOF'"                    deny "bash <<'EOF'$NL$X${NL}EOF"
hd3 "d3 python3 - <<'EOF'"               deny "python3 - <<'EOF'${NL}import os${NL}os.system('rm -rf $M/x')${NL}EOF"
hd3 "d4 cat <<'EOF' | sh"                deny "cat <<'EOF' | sh$NL$X${NL}EOF"
hd3 "d5 env bash <<'EOF'"                deny "env bash <<'EOF'$NL$X${NL}EOF"
hd3 "d6 cat > M/f <<'EOF'"               deny "cat > $M/f <<'EOF'${NL}x${NL}EOF"
# A variable in the target is not a literal: old reading (unresolved, so denied in a repo).
check "h d6b cat > \$M/f <<'EOF' (no agent, cwd=M)" deny "" "$(bash_json "" "$M" "cat > \$M/f <<'EOF'${NL}x${NL}EOF")"
check "h d6b cat > \$M/f <<'EOF' (agent, cwd=W)"    deny "" "$(bash_json a1 "$W" "cat > \$M/f <<'EOF'${NL}x${NL}EOF")"
hd3 "d7 cat > out <<'EOF', unterminated" deny "cat > $O/a <<'EOF'$NL$X"
hd3 "d8 #! body, then run"               deny "cat > /tmp/s.sh <<'EOF'$NL#!/bin/sh$NL$X${NL}EOF${NL}chmod +x /tmp/s.sh && /tmp/s.sh"
hd3 "d9 <<'EOF' inside double quotes"    deny "echo \"a <<'EOF'\"$NL$X${NL}EOF"
hd3 "d10 EOF) line"                      deny "gh pr create --body \"\$(cat <<'EOF'${NL}x${NL}EOF)\"$NL$X${NL}EOF$NL)\""
hd3 "d11 quoted then unquoted heredoc"   deny "cat > $O/a <<'EOF'${NL}x${NL}EOF${NL}cat <<EOF$NL\$($X)${NL}EOF"
hd3 "d12 comsub )\" in body + rm (bash 3.2)" deny "gh pr create --body \"\$(cat <<'EOF'${NL}a)\"$NL$X$NL\"\$(cat <<'Y'${NL}EOF$NL)\""
hd3 "A1 true; #<<'EOF'"                  deny "true$NL#<<'EOF'$NL$X${NL}EOF"
hd3 "A2 echo \$'x\\' <<'EOF' #'"         deny "echo \$'x\\' <<'EOF' #'$NL$X${NL}EOF"
hd3 "A3 echo \${x:-<<'EOF' }"            deny "echo \${x:-<<'EOF' }$NL$X${NL}EOF"
hd3 "B4 b\\ash <<'EOF'"                  deny "b\\ash <<'EOF'$NL$X${NL}EOF"
hd3 "B5 \$SHELL <<'EOF'"                 deny "\$SHELL <<'EOF'$NL$X${NL}EOF"
hd3 "C6 while read v p; do \$v \$p"      deny "while read v p; do \$v \$p; done <<'EOF'${NL}rm $M/x${NL}EOF"
hd3 "C7 patch -p0 <<'EOF'"               deny "patch -p0 <<'EOF'$NL--- $M/x$NL+++ $M/x$NL@@ -1 +1 @@$NL-a$NL+b${NL}EOF"
hd3 "C8 git apply --unsafe-paths <<'EOF'" deny "git apply --unsafe-paths <<'EOF'$NL--- $M/x$NL+++ $M/x${NL}EOF"
hd3 "C9 make -f - <<'EOF'"               deny "make -f - <<'EOF'${NL}all:$NL$TAB$X${NL}EOF"
hd3 "C10 read d <<'EOF'; rm -rf \"\$d\"" deny "read d <<'EOF'$NL$M/x${NL}EOF${NL}rm -rf \"\$d\""
hd3 "D11 cat > /tmp/s.sh; /tmp/s.sh"     deny "cat > /tmp/s.sh <<'EOF'$NL$X${NL}EOF$NL/tmp/s.sh"
hd3 "t1 after EOF: rm -rf M"             deny "cat > $O/a <<'EOF'${NL}x${NL}EOF${NL}rm -rf $M"
hd3 "t2 after EOF: mkdir M/x"            deny "cat > $O/a <<'EOF'${NL}x${NL}EOF${NL}mkdir $M/x"
hd3 "t3 after EOF: cd M && rm x"         deny "cat > $O/a <<'EOF'${NL}x${NL}EOF${NL}cd $M && rm x"
hd3 "t4 tee M/f <<'EOF'"                 deny "tee $M/f <<'EOF'${NL}x${NL}EOF"
# ~- ~+ ~N name OLDPWD, PWD and the dir stack: such a command is never stripped.
hd3 "t6 cd M && cd O && cat > ~-/pwn"    deny "cd $M && cd $O && cat > ~-/pwn <<'EOF'${NL}x${NL}EOF"
hd3 "t7 cd M && tee ~+/x"                deny "cd $M && tee ~+/x <<'EOF'${NL}x${NL}EOF"
hd3 "t8 after EOF: cd ~- && rm x"        deny "cd $M && cd $O && cat > $O/a <<'EOF'${NL}x${NL}EOF${NL}cd ~- && rm x"
hd3 "t9 cd M && cd O && cat > ~1/pwn"    deny "cd $M && cd $O && cat > ~1/pwn <<'EOF'${NL}x${NL}EOF"
hd3 "t5 cat >> M/f <<'EOF'"              deny "cat >> $M/f <<'EOF'${NL}x${NL}EOF"
# Bail-outs bound the work: none of these may take long or slip through.
hd=$(head -c 100000 /dev/zero | tr '\0' x)
pp=""; cc=""; for i in $(seq 1 3900); do pp="$pp( "; cc="$cc )"; done
ls5=""; for i in $(seq 1 5300); do ls5="${ls5}ls;"; done
nls=$(head -c 15500 /dev/zero | tr '\0' '\n'; echo .); nls=${nls%.}   # keep the newlines
for who in a1 ""; do
  if [ -n "$who" ]; then cw=$W; wl=agent; else cw=$M; wl="no agent"; fi
  timed "a8 ~100k heredoc + rm -rf M ($wl)" deny "$(bash_json "$who" "$cw" "cat > $O/a <<'EOF'$NL$hd${NL}EOF${NL}rm -rf $M")"
  timed "a9 heredoc; rm -rf M; ( x3900 ls ) x3900 ($wl)" deny "$(bash_json "$who" "$cw" "cat > $O/a <<'EOF'${NL}x${NL}EOF${NL}rm -rf $M; $pp ls$cc")"
  timed "a10 heredoc; rm -rf M; ls; x5300 ($wl)" deny "$(bash_json "$who" "$cw" "cat > $O/a <<'EOF'${NL}x${NL}EOF${NL}rm -rf $M;$ls5")"
  timed "a11 heredoc; rm -rf M + 15500 blank lines ($wl)" deny "$(bash_json "$who" "$cw" "cat > $O/a <<'EOF'${NL}x${NL}EOF${NL}rm -rf $M$NL$nls")"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
