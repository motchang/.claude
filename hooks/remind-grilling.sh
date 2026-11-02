#!/usr/bin/env bash
# UserPromptSubmit hook. When the prompt mentions 仕様, 要件, or the English
# words spec(s)/specification(s)/requirement(s) (any case),
# it reminds Claude to read ~/.claude/docs/grilling-rules.md and call
# Skill(grilling) before writing. Otherwise it prints nothing.
# It never blocks the prompt: every path exits 0, and a missing jq or a broken
# input only means no reminder.
# Output format: https://code.claude.com/docs/en/hooks.md#userpromptsubmit-decision-control
set -u

in=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# jq exits non-zero on invalid JSON or a non-string prompt; both mean "no match".
# English words need an ASCII boundary so that inspect, rspec, user_spec.rb,
# spec/ and a.spec.ts stay silent. jq's Oniguruma rejects lookbehind, so the
# boundary is spelled out as a character class.
en='(^|[^A-Za-z0-9_/.-])(spec(s|ification|ifications)?|requirements?)($|[^A-Za-z0-9_/-])'
printf '%s' "$in" |
  jq -e --arg en "$en" \
    '(.prompt | type) == "string" and (.prompt | test("仕様|要件") or test($en; "i"))' \
    >/dev/null 2>&1 || exit 0

msg='仕様・要件の作業なら、書き始める前に ~/.claude/docs/grilling-rules.md を Read し、Skill(grilling) を呼ぶ。既存仕様への増分なら、CLAUDE.md の再発火判定（ADR に値する選択／新しい節を生む／既存の決定・定義を変える）にどれが当たるかを一行で述べ、当たらないなら理由まで書く。'

jq -n --arg c "$msg" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}' 2>/dev/null
exit 0
