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
for r in opt-past opt-future opt-marker; do
  g init -q "$tmp/$r"; g -C "$tmp/$r" commit -q --allow-empty -m i
done
mkdir -p "$tmp/home/.claude/hooks" "$tmp/opt-marker/.claude"
touch "$tmp/opt-marker/.claude/no-isolation"
cat >"$tmp/home/.claude/hooks/no-isolation-repos" <<EOF
# test list
$tmp/opt-past until 2000-01-01
$tmp/opt-future/ until 2999-12-31
EOF
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
# The opt-out is judged on the cwd (or the Write dir) only, never on a target: a
# command from a guarded repo gains no route into an opted-out one.
check "o7 cwd=M cd opt-future && rm f"       deny "$R2" "$(bash_json a1 "$M" "cd $tmp/opt-future && rm f")"
check "o8 cwd=M git -C opt-future commit"    deny "$R2" "$(bash_json a1 "$M" "git -C $tmp/opt-future commit -m x")"
check "o9 cwd=W echo > opt-marker/a"         deny "$R2" "$(bash_json a1 "$W_SIB" "echo x > $tmp/opt-marker/a")"
check "o10 Write agent cwd=M opt-future/a"   allow ""  "$(write_json a1 "$M" "$tmp/opt-future/a")"
# Rule 1 (no agent) denies everything the original did, cwd-relative, cd ignored.
check "r1a cwd=M git -C /tmp commit (no agent)" deny "$R1" "$(bash_json "" "$M" "git -C /tmp commit -m x")"
check "r1b cwd=M cd /tmp && rm a (no agent)" deny "$R1" "$(bash_json "" "$M" "cd /tmp && rm a")"
check "r1c cwd=M make --dry-run (no agent)"  deny "$R1" "$(bash_json "" "$M" "make --dry-run")"
check "r1d Write cwd=M /tmp/new/x (no agent)" deny "$R1" "$(write_json "" "$M" "/tmp/nonexistent-$$/x")"
check "r1e cwd=M rm /tmp/f (no agent)"       allow ""  "$(bash_json "" "$M" "rm /tmp/f")"

# Over 200 segments (or 16384 chars) a command that mutates anything at all is
# denied as too long to judge; one that does not is allowed.
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
check "c1 cwd=W 200x true; cd ../main && commit" deny "$TL" "$(bash_json a1 "$W_SIB" "$pad cd ../main && git commit -m x")"
check "c2 cwd=W cd ../main && commit # 16K"  deny "$TL" "$(bash_json a1 "$W_SIB" "cd ../main && git commit -m x # $xs")"
check "c3 cwd=W git -C ../main commit # 16K" deny "$TL" "$(bash_json a1 "$W_SIB" "git -C ../main commit -m x # $xs")"
check "c4 cwd=W git -C M commit # 16K"       deny "$TL" "$(bash_json a1 "$W_SIB" "git -C $M commit -m x # $xs")"

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
