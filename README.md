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
- `hooks/no-isolation-repos` - the repositories where the worktree guard does not
  apply. It names internal repositories, so it lives in a private dotfiles repository
  and is symlinked in from there. Note that the guard matches on
  `git rev-parse --show-toplevel`, which resolves symlinks, so an entry for this
  repository has to be the path under `~/src` rather than `~/.claude`.
- `plugins/`, `projects/`, `sessions/`, `history.jsonl`, and the rest of the runtime
  state.

# who does the writing

Changes to a repository are made by a subagent working in a linked git worktree, not
by the main thread and not in the main checkout. `hooks/enforce-agent-worktree.sh`
enforces it as a PreToolUse hook: `Edit`, `Write` and `NotebookEdit` always, and the
Bash commands that actually change files in the repository.

The filter splits a command on shell separators, reads the word in command position,
and resolves redirect targets and path arguments against the repository, so
`grep -rn npm .` is a search and a redirect into `/tmp` is not a repository change. It
reads the subcommand for git, the node package managers, cargo, go and make:
`npm install` is guarded, `npm ls` is not. Reading, searching, building and testing
stay on the main thread, which is where their output is interpreted.

A repository opts out through `hooks/no-isolation-repos` or a `.claude/no-isolation`
file of its own. This one is on that list. A guard that routed every edit of its own
configuration through a worktree would be tiresome to maintain and would make a
mistake in the guard itself hard to undo.

`CLAUDE.md` carries the part no hook can. Review is read-only, so no deny ever fires
for it, and wanting the reviewing agent to be a different one from the agent that
wrote the change is a policy rather than a mechanism. It also states that delegation
needs no per-session permission, because the harness may inject an instruction not to
use the Agent tool unless the user asked for it - the sentence carries its own
exception, and a standing instruction here satisfies it once instead of by hand every
session. That file is user-level: it applies to every project, not only this one.

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
