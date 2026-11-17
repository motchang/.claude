# ~/.claude

User-level Claude Code configuration - settings, hooks, skills, and the instructions
that apply to every project. The repository lives under `~/src` like any other, and
`~/.claude` is a symlink to it, the same arrangement as `~/.emacs.d`.

# a warning about git clean

Claude Code keeps its entire working state in this directory - `projects/`,
`sessions/`, `history.jsonl`, `plugins/`, several hundred megabytes of it - and all of
it is ignored rather than tracked. `git clean -xdf` here deletes every session
transcript and every installed plugin. The transcripts cannot be regenerated.

The same asymmetry applies to putting this repository back on a machine that has
already run Claude Code: adopt what is on disk with `git reset origin/main`, never
`git checkout`. Reset leaves the working state alone and lets the differences show up
as modifications to look at. Checkout writes over it.

# what is tracked

By allowlist, and very little of it. `.gitignore` drops everything with `*` and then
names what to keep. That is not tidiness. This directory mixes configuration with the
record of every session: directory names under `projects/` spell out the absolute path
of every repository worked in, and `history.jsonl`, `sessions/`, `file-history/` and
`paste-cache/` hold conversation text and file contents verbatim. A list of exclusions
eventually misses one, and the cost of missing one is not symmetric with the cost of an
extra line here.

Adding a file to the repository means adding a `!` line for it first. Until then
`git add` will not stage it. Whole directories are deliberately not allowlisted:
`hooks/` also holds a script herdr generates and a symlink into a private repository,
and `skills/` also holds skills that plugins and vendors install.

Left untracked on purpose:

- `hooks/herdr-agent-state.sh` - herdr writes it and overwrites it whenever the
  integration is reinstalled. `settings.json` calls it, so a machine without herdr
  logs a failed hook and carries on.
- `hooks/no-isolation-repos` - the repositories the main-checkout guard leaves to the
  main thread (see below). It names internal repositories, so it lives in a private
  dotfiles repository and is symlinked in from there.
- `plugins/`, `projects/`, `sessions/`, `history.jsonl`, and the rest of the runtime
  state.

# who does the writing

Changes to a repository are made by a subagent working in a linked git worktree, not
by the main thread and not in the main checkout. `hooks/guard-main-checkout.sh`
enforces the part of that a hook can see. It is a PreToolUse hook on `Edit`, `Write`
and `NotebookEdit`, and it denies a write into a main checkout under `~/src`, from the
main thread and from a subagent alike. It is a fence against starting to edit in the
wrong place by mistake, not a wall against something trying to get round it.

A write is denied when all of these hold for the real path of its target:

- it is under `~/src`;
- it is in the work tree of a git repository whose git dir is its common dir, which is
  what tells a main checkout from a linked worktree. A submodule counts as part of a
  main checkout unless its superproject is a linked worktree;
- it is not inside `.git`, that is, not under the git dir or the common dir that git
  reports for it. With `core.worktree` set, git counts `.git` as part of the work
  tree, and the hook still lets `.git` through;
- neither the repository nor, for a submodule, its superproject opts out (see below);
- it is not an untracked file that an ignore rule drops. A tracked file stays guarded
  even when an ignore rule matches it.

So a write goes through when it lands outside `~/src` or outside any repository, in a
linked worktree, inside `.git`, or on an ignored file such as a build output. The
target is judged where it resolves to: symlinks on the path are resolved, one at the
end included, so writing through a link into a main checkout is denied and writing to
a tracked link that points out of `~/src` is not. A file that does not exist yet
belongs to the repository of its nearest existing parent. Only the target counts,
never the session's working directory, and a submodule is looked at one level up
only. Whatever the hook cannot read - no `jq`, broken input, git failing - goes
through. So does a target that is not an absolute path, one starting with `~`
included, and the hook does not join it to the session's working directory. Such a
target does not reach the hook in practice: Claude Code 2.1.326 expands `~`, joins a
relative path to the working directory and resolves `..` before it runs a
`PreToolUse` hook (seen for `Edit`, `Write` and `NotebookEdit`). A deny names the
repository's top, with the home directory written as `~`, and tells Claude to hand
the change to a subagent. The comment at the top of the hook is the exact account;
this is the outline.

Bash is not hooked. An earlier guard read Bash commands as well and denied the ones
whose destination it could not resolve, and it stopped far more work than it
protected. Keeping Bash off a main checkout is left to `CLAUDE.md`.

`CLAUDE.md` carries the part no hook can: keeping Bash off a main checkout, making the
worktree in the right repository when a change is for a repository other than the one
the session started in, and review. Review is read-only, so no deny ever fires for it,
and wanting the reviewing agent to be a different one from the agent that wrote the
change is a policy rather than a mechanism. It also states that delegation needs no
per-session permission, because the harness may inject an instruction not to use the
Agent tool unless the user asked for it - the sentence carries its own exception, and
a standing instruction here satisfies it once instead of by hand every session. That
file is user-level: it applies to every project, not only this one.

# opting out of the guard

A repository opts out with a `.claude/no-isolation` file at its top, or with a line in
`hooks/no-isolation-repos`, and there the main thread edits directly. This one is on
that list. A guard that routed every edit of its own configuration through a worktree
would be tiresome to maintain and would make a mistake in the guard itself hard to
undo. A submodule also goes through when its superproject opts out. A repository
nested inside an opted-out one without being its submodule is judged on its own.

The list takes one repository per line, as `<path> [until YYYY-MM-DD]`:

- The path may start with `~`, and may be written through `~/.claude` or as the
  directory under `~/src`. The entry and the repository are both turned into real
  paths before they are compared, so either spelling matches.
- An entry with `until` holds through that day. The date is compared as a string and
  not otherwise checked.
- Everything from a `#` to the end of the line is a comment, in the middle of a line
  too.

If the list cannot be read - it is missing, or the symlink to it is broken - it counts
as empty, and the deny says so. The marker and the list are themselves denied to every
write, wherever they are, so only the user changes them.

`CLAUDE_ENFORCE_OFF=1` in the environment the hook runs in turns it off. It is the
user's switch: `CLAUDE.md` tells Claude not to set it.

# settings.json

Hook commands are written `bash "$HOME/.claude/hooks/..."`, never as absolute paths.
The command string is passed to a shell, so `$HOME` expands when the hook runs, and an
absolute path would carry this machine's account name into a public repository.

Two things rewrite parts of this file on their own, and both write absolute paths when
they do:

- herdr replaces its own `SessionStart` entry when the integration is reinstalled.
- the auto-mode setup fills in `autoMode.environment`, which is also where an
  employer's infrastructure would end up if it were configured on a work machine.

Neither is a leak, because the guard below refuses the commit. But both mean an edit
here can come back, and the refusal is what tells you.

# secret guard

This repository shares one installation of the commit and push guard with the public
dotfiles repository. The hooks live outside any working tree precisely so that several
repositories can point at the same copy. Install it from the dotfiles repository
first, then arm this one - until this runs, the guard is simply off:

	git config core.hooksPath "$HOME/.config/dotfiles-guard/hooks"

The guard refuses absolute home paths, strings shaped like credentials, and vocabulary
that would name an employer. It also refuses a staged path that `.gitignore` would have
dropped, which is what makes the allowlist above load-bearing rather than advisory -
`git add -f` does not get round it.
