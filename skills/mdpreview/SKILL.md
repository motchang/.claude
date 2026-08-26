---
name: mdpreview
description: Render a markdown file - mermaid diagrams, GitHub alerts, syntax highlighting, and a table of contents - in a herdr-browser pane, or in the desktop browser with `--browser`, with live reload on save. Use when the user asks to preview, render, or visually check a .md file ("プレビュー", "レンダリング結果を見せて", "mermaid が描けているか確認して"), asks to see that preview in their own browser ("ブラウザで開いて"), or asks whether a diagram or the structure of a markdown file comes out right. Also use when an open preview pane stops scrolling or ignores the mouse ("スクロールが効かない"), which is a wedged Chrome tab rather than a page problem - `mdpreview --reset` replaces it. Not for reading markdown as text - use Read for that - and not something to do to a markdown file the user has not asked to see.
---

# mdpreview

Previews a markdown file in a Chromium pane embedded in the current herdr tab,
or in the desktop browser. Mermaid renders; the page reloads itself when the file
is saved.

## Usage

```sh
mdpreview path/to/file.md              # a pane in this tab
mdpreview --browser path/to/file.md    # the desktop browser instead
mdpreview --browser                    # the same, on the file previewed most recently
```

That is the whole flow. The command starts the render server on first use,
reuses it afterwards, and settles the surface itself: an existing browser pane in
this tab is reused, and a tab without one gets a fresh pane split off to the
right. Running it twice does not stack up panes, so it is safe to just run it.
After an edit to a file that is already being previewed, do nothing at all: the
page reloads on save.

`--browser` shows the preview in the desktop browser, and works inside a herdr
session too - that is how a preview goes to the browser rather than into a pane.
It takes focus, unlike a pane, so it pulls the user away from whatever they were
looking at; use it when they asked for their browser, not by default. Running it
twice on the same file reloads the tab that is already open instead of opening a
second one - except for a tab Chrome has discarded or frozen in the background,
which reads as gone and costs an occasional spare tab. Outside a herdr session
there is no tab to scope to and no pane to split from, so a plain
`mdpreview file.md` goes to the desktop browser as well; previewing from a plain
terminal works and is worth doing.

**Do not work out the state of the preview yourself.** Whether this tab has a
browser pane, which pane it is, which view belongs to it, whether Chrome has
registered that view yet - every mode of `mdpreview` answers all of that
internally, waiting where a wait is needed. Running `herdr pane list`,
`herdr-browser views`, or `jq` over either of them to decide what to do next is
work the script has already done, and it is slower and less correct than the
answer already in the script: a view is registered before it knows its pane, so a
view list read from outside reports "nothing here" for a pane that is perfectly
fine.

`HERDR_BROWSER_VIEW_ID` never needs to be exported, and bare `herdr-browser`
never needs to be called. `mdpreview <anything else>` is `herdr-browser` with
this tab's preview already named:

```sh
mdpreview text                                # rendered text content
mdpreview console                             # page errors
mdpreview screenshot --output /tmp/preview.png
mdpreview eval 'document.title'
```

Any herdr-browser command works this way - the word is passed straight through,
and herdr-browser rejects one it does not have. All of them reach the page over
CDP, which reaches a herdr-browser pane and nothing else: a browser tab has no
view to attach to, so these need a pane and refuse without one rather than
answering about some other Chrome. A first argument ending in `.md`, `.markdown`
or `.mdown`, or containing a `/`, is a file to preview instead, so a file whose
name looks like a command needs `./` in front of it.

## Scope

Preview surfaces are independent. Each page holds its own file, so a pane in this
tab, a pane in another and any number of browser tabs can show different files at
once, and previewing a second file no longer navigates the first away from what
it was showing.

That is not a reason to spread previews around. Preview the file the user is
working on or asked about, and put it on the surface they are already looking at.
Do not preview a markdown file nobody mentioned just because it was read or
edited in passing, and do not add a browser tab for a file that is already up in
a pane.

## Reading the result back

Reading the page back needs a pane: these commands reach the page over CDP, and a
herdr-browser pane is the only thing reachable that way.

```sh
mdpreview README.md && mdpreview text            # preview, then read it back
mdpreview screenshot --output /tmp/preview.png   # then Read the png
```

A browser tab cannot be read back. From inside a herdr session, open a pane on
the same file with `mdpreview README.md` and read that one - the tab keeps its
own file and stays where it is. From a plain terminal there is no pane to open at
all, so say that the page cannot be read back rather than reporting on a page
nobody looked at.

Reach for `mdpreview console` when a mermaid block renders as an error box -
mermaid parses in the browser, so its diagnostics only surface there.

`mdpreview --view` still prints the view id for a command that needs it in the
environment, and `mdpreview --pane` prints this tab's pane ids. Neither is needed
for the commands above.

## When the pane stops responding to the mouse

Chrome sometimes stops acknowledging pointer input while everything else about
the page stays healthy. The wheel scrolls nothing, and the pane fills up with

```
mouse move failed: timed out waiting for CDP Input.dispatchMouseEvent
```

which the viewer writes straight onto the page, so it surfaces on the next
redraw - pressing the herdr prefix is usually what reveals it. `herdr-browser
status` still answers, `text` still returns the document, and a reload does not
clear it: the wedge belongs to the Chrome tab, not to the document.

```sh
mdpreview --reset
```

Run it from the tab whose preview is stuck - it is tab-scoped like the other pane
modes, so from another tab it just opens a second preview somewhere the stuck one
is not, and from a plain terminal it refuses for want of a tab. It replaces this
tab's preview pane with a fresh one on the same file, then dispatches a
zero-delta wheel to check that pointer input answers before reporting. If a new
pane is not enough it restarts the browser daemon and tries once more, which also
covers a Chrome that has stopped answering altogether.

`mdpreview --reset path/to/other.md` resets onto a different file instead. With
no file argument it comes back to what a pane was last pointed at, not to a file
opened with `--browser`.

The daemon restart is the second stage only, and it is session-wide: every other
herdr-browser pane in the session drops to "session ended" until reopened. It
says so on stderr when it gets that far, so a reset that reports
`reset ok - new preview pane` disturbed nothing else.

Do not reset a preview the user has not complained about and that reads back
fine - `mdpreview text` working is not evidence that scrolling does.

## Reading the pane's own errors

The viewer reports its failures by writing them onto the pane and nowhere else -
there is no log file. They are still readable without asking the user what the
pane says:

```sh
mdpreview --screen
```

That is the pane's visible screen: the toolbar line, and under it whatever the
viewer has written over the page. It is the counterpart to `mdpreview console`,
which reports the page's errors rather than the viewer's.

## Shutting down

```sh
mdpreview --stop        # stops the render server; panes and tabs stay open
```

Closing the preview pane, or the browser tab, is the user's call - leave it alone
unless asked. `--reset` is the exception: replacing the pane is the whole point
of it.

## When it fails

- `dependencies missing - run 'bun install' in ...` - the render server's
  node_modules are absent. Run `bun install` in that directory.
- `could not read the herdr-browser view list` - `herdr-browser` is not on PATH,
  or the plugin is not installed
  (`herdr plugin install ogulcancelik/herdr-browser`).
- `could not read the herdr pane list` - `herdr` itself is the problem, not the
  browser plugin. Nothing was previewed; the pane is untouched.
- `the herdr-browser pane in this tab has not registered a view` - a browser pane
  is there but its Chrome never came up. `mdpreview --reset` replaces the pane
  and, failing that, the daemon behind it.
- `the render server on <port> would not take <file> - <reason>` - the server
  will not render that path: a suffix outside `.md`, `.markdown` and `.mdown`, or
  a file it cannot read. The reason is the server's own, and nothing was
  navigated - no surface moved off what it was showing.
- `no way to open a browser - neither open nor xdg-open is on PATH` - a browser
  preview has no way to reach one. Nothing was previewed; the message carries the
  URL, and inside a herdr session a pane preview is still the way to show it.
- `'<word>' would be run against a herdr-browser view` - outside a herdr
  session there is none, and the read-back commands need one. Run it from a herdr
  pane; if the word was meant as a file, spell it with a `.md` suffix or a `./`
  prefix.
- `no herdr-browser pane in this tab - run 'mdpreview <file.md>' to open one` -
  inside a session, with the only preview a `--browser` tab. The tab cannot be
  driven; open a pane on the file and read that one back.
- `no herdr-browser view anywhere to name` - `--view` with no herdr-browser pane
  open anywhere. Outside a herdr session it still hands back whatever view the
  daemon has, but a `--browser` tab is not one and never becomes one.
- `--pane needs a herdr pane to scope to` - `--pane`, `--screen` and `--reset`
  are all about this tab's pane, and from a plain terminal there is no tab for
  them to answer about.
- `nothing is being previewed` - `--browser` or `--reset` with no file argument,
  and the render server has nothing to come back to. Name the file:
  `mdpreview --browser path/to/file.md`.
- `reset failed - pointer input still times out` - a new pane and a new daemon
  both came up and neither took pointer input, so this is not the usual wedge.
  The page itself still renders and reads back; report that rather than resetting
  again in a loop.
- The port is 43128 by default; `MDPREVIEW_PORT` overrides it. Note that a
  second port means a second server, not a second visible preview.
