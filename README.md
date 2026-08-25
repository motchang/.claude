# ~/.claude

User-level Claude Code configuration - settings, hooks, and the skills that apply
to every project. The repository lives under `~/src` like any other, and `~/.claude`
is a symlink to it, the same arrangement as `~/.emacs.d`.

	git clone ssh://git@github.com/motchang/.claude ~/src/github.com/motchang/.claude
	ln -s ~/src/github.com/motchang/.claude ~/.claude

Do that before the first `claude` run on a fresh machine, while `~/.claude` does
not exist yet. On a machine that has already run Claude Code, move what is there
into place and link it back instead - the same filesystem, so the move is instant
and open file handles follow it:

	command mv ~/.claude ~/src/github.com/motchang/.claude
	ln -s ~/src/github.com/motchang/.claude ~/.claude
	cd ~/.claude
	git init -b main
	git remote add origin ssh://git@github.com/motchang/.claude
	git fetch origin
	git reset origin/main

`git reset` rather than `checkout`, so what is already on disk is left where it is:
the tracked files are adopted, not written over. Anything that differs then shows up
as a modification to look at.

The remote is SSH on purpose. Over HTTPS git picks the credential helper for the
active `gh` account, which on a work machine is not the one that owns this
repository.

# a warning about git clean

Claude Code keeps its entire working state in this directory - `projects/`,
`sessions/`, `history.jsonl`, `plugins/`, several hundred megabytes of it - and all of
it is ignored rather than tracked. `git clean -xdf` here deletes every session
transcript and every installed plugin. The transcripts cannot be regenerated.

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
first, then arm this one:

	git config core.hooksPath "$HOME/.config/dotfiles-guard/hooks"

The guard refuses absolute home paths, strings shaped like credentials, and vocabulary
that would name an employer. It also refuses a staged path that `.gitignore` would have
dropped, which is what makes the allowlist above load-bearing rather than advisory -
`git add -f` does not get round it.
