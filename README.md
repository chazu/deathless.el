# deathless

A live dashboard for your [agent-shell](https://github.com/xenodium/agent-shell)
sessions, built with [vui.el](https://github.com/d12frosted/vui.el).

```
  ◆ NEEDS YOU  api  Refactor auth middleware                  Claude        0s
               Opus 5.5 · ctx 45.2k/200.0k (23%) · $0.42
               ▌ ⚠ edit: Edit src/auth/middleware.ts
               ▌  Allow   Always Allow   Reject   Show
                Open   Interrupt   Kill

  ◑ WORKING    foo  Fix flaky integration test in CI           Claude     1m03s
               Opus 5.5 · ctx 45.2k/200.0k (23%) · $0.42
               ↳ Run npm test -- --grep flaky
                Open   Interrupt   Kill
```

Each session is a card that shows:

- its status
- the project it works in
- what it is doing right now
- buttons for what you can do about it

When a session needs permission, the request appears on its card with the
options as buttons. You can answer it without opening the shell.

The cards update from agent-shell's own events, so a card changes as soon as its
agent does. Nothing polls. A timer redraws once a second only to keep the clocks
running.

## Installation

```elisp
(use-package deathless
  :straight (deathless :type git :host github :repo "chazu/deathless.el")
  :bind ("C-c a d" . deathless))
```

From a local checkout:

```elisp
(add-to-list 'load-path "~/dev/elisp/deathless")
(require 'deathless)
```

## Usage

Run `M-x deathless`. It opens the dashboard in a side window and starts
`deathless-tracking-mode`, which tracks every agent-shell buffer from then on.

| Key        | On a card                          |
|------------|------------------------------------|
| `RET`, `o` | open the session                   |
| `a`        | allow the pending tool call once   |
| `A`        | always allow it                    |
| `r`        | reject it                          |
| `s`        | show the request in the shell      |
| `i`        | interrupt the running turn         |
| `k`        | kill the session                   |
| `R`        | restart with a fresh conversation  |
| `m` / `M`  | set session mode / model           |
| `t`        | view ACP traffic                   |

| Key       | Anywhere                                 |
|-----------|------------------------------------------|
| `n` / `p` | next / previous card                     |
| `N`       | next card waiting on you (wraps around)  |
| `TAB`     | next button                              |
| `c`       | new agent (prompts for a directory)      |
| `v`       | switch between compact and full cards    |
| `g`       | re-read every session                    |
| `q`       | quit                                     |

Every button is also clickable with the mouse.

## Compact cards

By default each card is one line: status, project, title, current tool
call and clock.
A card opens up only when it needs you. A pending permission shows its buttons,
and a failure shows its error:

```
  ◆ NEEDS YOU  api  Refactor auth middleware                                 0s
               ▌ ⚠ edit: Edit src/auth/middleware.ts
               ▌  Allow   Always Allow   Reject   Show
  ◒ WORKING    foo  Fix flaky integration t…  ↳ Run npm test -- --gre…    1m03s
  ● DONE       api  Refactor auth middleware                            12m ago
```

Set `deathless-compact` to `nil` for full cards, with details and buttons, or to
`auto` to go compact only when the full cards would not fit the window. Press
`v` to switch in the dashboard.

## Card layout

Two options lay out a card's first line. Each one lists parts for the left
side and parts for the right side:

```elisp
(setq deathless-card-header-format          ; full cards
      '(:left (status project title) :right (agent clock)))
(setq deathless-card-compact-format         ; compact cards
      '(:left (status project title activity) :right (clock)))
```

Those are the defaults. The parts are:

| Part       | Shows                                                        |
|------------|--------------------------------------------------------------|
| `status`   | the status pill                                              |
| `project`  | the project the session works in                             |
| `title`    | the session title, a button that opens the session           |
| `activity` | the tool call a working session is running                   |
| `agent`    | the agent's name                                             |
| `dir`      | the session's directory, shortened                           |
| `clock`    | how long the turn has run, or how long ago it ended          |

A part with nothing to show is left out. The right side keeps its full width.
`title` and `activity` share what is left and are cut to fit. A project name is
cut at `deathless-project-max-width` columns (24). When `project` comes before
`title`, it is padded so the titles line up.

The project of a session in a rat-kingdom worktree
(`.../rat-kingdom/worktrees/<repo>/<id>`) is `<repo>`. Otherwise it is the name
of the top of the session's Git work tree, or else the name of its directory.
Its face is `deathless-project`.

To get the layout from before project names back:

```elisp
(setq deathless-card-header-format '(:left (status title) :right (agent dir clock))
      deathless-card-compact-format '(:left (status title activity) :right (dir clock)))
```

### Parts of your own

`deathless-card-parts` maps each part to a function. The function gets the
session and its status, and returns a string, or `nil` to leave the part out.
Give the string a face with `propertize`. This part shows the session's model:

```elisp
(defun my-deathless-model (session _status)
  (when-let* ((model (deathless-session-model session)))
    (propertize model 'face 'deathless-meta)))

(add-to-list 'deathless-card-parts '(model . my-deathless-model))
(setq deathless-card-compact-format
      '(:left (status project title activity) :right (model clock)))
```

The functions run on each redraw, which is once a second while a clock runs, so
keep them fast. Only `title` and `activity` are cut to fit, so keep other parts
short. `deathless-card-width` holds the width of the card being drawn.

To draw a built-in part differently, put an entry for it in front:
`(add-to-list 'deathless-card-parts '(title . my-title))`. The first part of a
line always gets a `deathless-buffer` text property. The keys on a card use it
to find the session, so you do not have to add it.

## Statuses

| Status    | Meaning                                                |
|-----------|--------------------------------------------------------|
| NEEDS YOU | waiting on a permission request                        |
| WORKING   | running a turn; the card shows the latest tool call    |
| DONE      | a turn finished while the shell was out of view        |
| FAILED    | the last turn hit an error                             |
| STOPPED   | the last turn ended early (cancelled, max tokens, ...) |
| READY     | idle                                                   |
| STARTING  | the agent is still starting up                         |
| EXITED    | the agent process is gone                              |

## Customization

| Option                            | Default        | Purpose                                     |
|-----------------------------------|----------------|---------------------------------------------|
| `deathless-display-buffer-action` | right side window | where the dashboard appears              |
| `deathless-open-action`           | `pop-to-buffer` | how a session is opened                    |
| `deathless-order`                 | `stable`       | `attention` puts waiting sessions first     |
| `deathless-compact`               | `t`            | one-line cards: `t`, `nil` or `auto`        |
| `deathless-card-header-format`    | see above      | first line of a full card                   |
| `deathless-card-compact-format`   | see above      | line of a compact card                      |
| `deathless-card-parts`            | built-ins      | functions that draw the parts               |
| `deathless-project-max-width`     | 24             | widest a project name grows                 |
| `deathless-max-width`             | 100            | widest a card grows                         |
| `deathless-confirm-kill`          | `t`            | ask before killing a session                |

All colours are faces in the `deathless` group (`M-x customize-group RET deathless`).

## Development

```sh
make test                 # VUI=path/to/vui if it is not in straight's build
make lint                 # byte-compile with warnings as errors, and checkdoc
```

`make test` runs:

```sh
emacs -Q --batch --eval '(setq load-prefer-newer t)' \
  -L . -L test -L path/to/vui -l test/deathless-test.el \
  -f ert-run-tests-batch-and-exit
```

The tests need only vui. They fake a shell as a buffer that has an
`agent-shell--state` alist and a live process.
