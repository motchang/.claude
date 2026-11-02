#!/usr/bin/env bash
# Tests for remind-grilling.sh. Feeds UserPromptSubmit JSON (or junk) to the
# hook and checks that it exits 0 with no stderr, and that it emits the
# reminder only when the prompt mentions 仕様, 要件, spec or requirements.
# Usage: remind-grilling.test.sh [path/to/remind-grilling.sh]
# The default is the installed copy under ~/.claude. In a worktree the change is
# not merged yet, so pass the worktree's hooks/remind-grilling.sh as the argument.
set -u
hook=${1:-$HOME/.claude/hooks/remind-grilling.sh}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A PATH that has cat but no jq, for the "jq missing" case.
mkdir "$tmp/nojq"
ln -s "$(command -v cat)" "$tmp/nojq/cat"

pass=0 fail=0

# check <label> <remind|silent> <stdin> [PATH for the hook]
check() {
  local label=$1 want=$2 input=$3 hpath=${4:-$PATH} out rc err ev ctx got
  out=$(printf '%s' "$input" | PATH=$hpath "$BASH" "$hook" 2>"$tmp/stderr"); rc=$?
  err=$(cat "$tmp/stderr")
  ev=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  if [ "$rc" != 0 ] || [ -n "$err" ]; then got="error(rc=$rc err=${err:0:200})"
  elif [ -z "$out" ]; then got=silent
  elif [ "$ev" = UserPromptSubmit ] && [[ $ctx == *grilling-rules.md* ]] && [[ $ctx == *"Skill(grilling)"* ]]; then got=remind
  else got="bad-output(${out:0:120})"
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf 'PASS  %s\n' "$label"
  else
    fail=$((fail+1)); printf 'FAIL  %s  (want %s, got %s)\n' "$label" "$want" "$got"
  fi
}

p() { jq -n --arg p "$1" '{session_id:"s",hook_event_name:"UserPromptSubmit",cwd:"/",prompt:$p}'; }

check "ja 仕様"              remind "$(p 'ログイン機能の仕様を書いて')"
check "ja 要件"              remind "$(p '要件定義を始めたい')"
check "en spec lower"        remind "$(p 'draft a spec for the importer')"
check "en SPEC upper"        remind "$(p 'Update the SPEC with the new endpoint')"
check "spec を書いて"         remind "$(p 'spec を書いて')"
check "draft a spec."        remind "$(p 'draft a spec.')"
check "specs"                remind "$(p 'specs')"
check "specification"        remind "$(p 'specification')"
check "SPEC alone"           remind "$(p 'SPEC')"
check "requirements doc"     remind "$(p 'requirements doc を書いて')"
check "inspect this"         silent "$(p 'inspect this')"
check "special case"         silent "$(p 'special case')"
check "respect"              silent "$(p 'respect')"
check "aspect"               silent "$(p 'aspect')"
check "rspec を流して"        silent "$(p 'rspec を流して')"
check "spec/ path"           silent "$(p 'spec/models/user_spec.rb が落ちる')"
check "a.spec.ts"            silent "$(p 'a.spec.ts')"
check "jq missing"           silent "$(p '仕様を書いて')" "$tmp/nojq"
check "no keyword ja"        silent "$(p 'このバグを直して')"
check "no keyword en"        silent "$(p 'run the tests')"
check "prompt empty"         silent "$(p '')"
check "prompt missing"       silent '{"hook_event_name":"UserPromptSubmit"}'
check "prompt not a string"  silent '{"prompt":["仕様"]}'
check "invalid json"         silent '{"prompt": "仕様'
check "not json at all"      silent 'spec 仕様 要件'
check "empty stdin"          silent ''

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
