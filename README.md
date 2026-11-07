# deathless

A live dashboard for your [agent-shell](https://github.com/xenodium/agent-shell)
sessions, built with [vui.el](https://github.com/d12frosted/vui.el).

```
 deathless                             1 need you · 1 done · 1 working · 1 idle
───────────────────────────────────────────────────────────────────────────────

  ◆ NEEDS YOU  Refactor auth middleware                              Claude  0s
               ~/dev/foo · Opus 5.5 · ctx 45.2k/200.0k (23%) · $0.42
               ▌ ⚠ edit: Edit src/auth/middleware.ts
               ▌  Allow   Always Allow   Reject   Show
                Open   Interrupt   Kill

  ◑ WORKING    Fix flaky integration test in CI                   Claude  1m03s
               ~/dev/foo · Opus 5.5 · ctx 45.2k/200.0k (23%) · $0.42
               ↳ Run npm test -- --grep flaky
                Open   Interrupt   Kill
```

Each session is a card that shows:

- its status
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
| `c`       | new agent                                |
| `g`       | re-read every session                    |
| `q`       | quit                                     |

Every button is also clickable with the mouse.

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
| `deathless-max-width`             | 100            | widest a card grows                         |
| `deathless-confirm-kill`          | `t`            | ask before killing a session                |

All colours are faces in the `deathless` group (`M-x customize-group RET deathless`).

## Development

```sh
emacs -Q --batch --eval '(setq load-prefer-newer t)' \
  -L . -L test -L path/to/vui -l test/deathless-test.el \
  -f ert-run-tests-batch-and-exit
```

The tests need only vui. They fake a shell as a buffer that has an
`agent-shell--state` alist and a live process.
