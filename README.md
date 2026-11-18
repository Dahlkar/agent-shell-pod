# agent-shell-pod

An Orca-style sidebar and dashboard for [agent-shell](https://github.com/xenodium/agent-shell).
Sessions are grouped by **project.el project → git worktree → agent**, with live status,
notifications and a jump-to-next-agent command. There are no tabs: the sidebar is a normal
side window next to whatever you're editing.

```
 Agents                 ◉ 1  ✔ 1  ◐ 1│Claude Code · feat/checkout-v2
 ▾ acme-web                     ◉2 4 │
   ▾ main                    primary │> Wire the new payment step into the checkout reducer.
     ● Refactor auth mi… opus-4.5 2m │
   ▾ exp/search                      │▸ Read src/checkout/reducer.ts
     ✔ Search ranking   opus-4.5 now │▸ Edit src/checkout/steps.ts  +42 -7
       Worked for 2m 14s             │◐ Running npm test -- checkout
   ▾ feat/checkout-v2                │
▌    ◐ Wire payment st… opus-4.5 now │
       Working for 16s               │
   ▾ fix/eu-promo                    │
     ◉ EU promo codes      gpt-5 now │
       Needs your input              │
   + New agent                       │
 ▸ infra                             │
 ──────────────────────────────────  │
 ctx  ███████░░░ 68%                 │
 cost $1.68 all sessions             │
```

`M-x agent-shell-pod-dashboard` shows the same tree as a full-width, magit-style buffer with a
**Needs you** section at the top.

## Install

Requires Emacs 29.1+ and agent-shell.

```elisp
(use-package agent-shell-pod
  :vc (:url "https://github.com/YOU/agent-shell-pod" :rev :newest)
  :after agent-shell
  :bind-keymap ("C-c a" . agent-shell-pod-command-map)
  :config
  (agent-shell-pod-mode 1)
  (keymap-set project-prefix-map "a" #'agent-shell-pod-new-session)
  (add-to-list 'project-switch-commands '(agent-shell-pod-new-session "Agent") t))
```

Or put `agent-shell-pod.el` on your `load-path` and `(require 'agent-shell-pod)`.

## Doom Emacs

Put the file in `~/.config/doom/lisp/`, keep `(package! agent-shell)` in `packages.el`, and add
this to `config.el`:

```elisp
(add-load-path! "lisp")

(after! agent-shell
  (setq agent-shell-preferred-agent-config 'claude-code))

(use-package! agent-shell-pod
  :hook (doom-after-init . agent-shell-pod-mode)
  :init
  (setq agent-shell-pod-session-display 'side-window))
```

`agent-shell-pod-mode` sets up the keys itself: `SPC l` opens `agent-shell-pod-menu`,
`SPC m l` in an agent opens `agent-shell-pod-session-menu`, and the sidebar and dashboard get
normal-state keys. Change the letters with `agent-shell-pod-leader-key` and
`agent-shell-pod-localleader-key`, set either to nil to skip it, or set
`agent-shell-pod-setup-keys` to nil to do all bindings yourself.

## Global commands

| Key (with `C-c a` prefix) | Command | |
|---|---|---|
| `s` | `agent-shell-pod-toggle` | Open or close the sidebar |
| `d` | `agent-shell-pod-dashboard` | Full dashboard |
| `n` | `agent-shell-pod-new-session` | New agent in the current project (`C-u` to pick a project) |
| `w` | `agent-shell-pod-new-worktree-session` | New branch, worktree and agent in one go |
| `j` | `agent-shell-pod-next-attention` | Jump to the next agent that needs you |
| `b` | `agent-shell-pod-switch` | Switch to any agent with completion |

## Menus

`agent-shell-pod-menu` is a transient for the project you're in. Items are greyed out when they
don't apply, for example "Open agent" when the project has no agent yet.

```
Agents  acme-web main  ● ✔ ◉ ◐
This project                         All agents
 s Start agent                        w Toggle sidebar
 W Start agent in new worktree        d Dashboard
 o Open agent                         j Next needing you
 b Toggle between agent and buffer    a Switch agent
 t Show or hide agent
 q Close agent
```

`agent-shell-pod-session-menu` works inside an agent buffer. It holds agent-shell's own
commands (insert, compose, mode, model, thought level, clear, interrupt, fork, transcript,
logs) plus the pod commands: back to buffer, sidebar, new agent, switch, label and close.

"This project" means the project of the current buffer, or of the item at point in the sidebar.
Agents in the same worktree as you come first, so `b` from a file in `feat/x` goes to the agent
working on `feat/x`.

Set `agent-shell-pod-session-display` to `side-window` to keep agents in a side window next to
your code, like agent-shell-sidebar does. The default, `main-window`, uses the window you
last worked in.

## Sidebar and dashboard keys

Press `?` for a menu of every action, with the ones that don't apply to the item at point greyed
out. The same keys work in Emacs and in evil normal state.

| Key | Action |
|---|---|
| `RET` / click | Open session · fold heading · start agent on `+ New agent` |
| `TAB` | Fold project or worktree |
| `o` / `O` | Peek at session · open it in another window |
| `j` / `k` | Next / previous item (also `n` / `p` outside evil) |
| `c` | New agent. On a worktree or session line it starts there; on a project it asks *current checkout / new worktree / existing worktree* |
| `w` / `W` | New agent in a fresh worktree · remove the worktree at point (`C-u` to force) |
| `J` | Jump to next agent that needs you |
| `x` `r` `R` `i` | Kill · label · restart · interrupt |
| `m` `M` | Set session mode · set model |
| `f` `d` `v` `P` | Find file · Dired · Magit/vc-dir · `project-switch-project` at point |
| `+` / `-` | Add a project · hide a project |
| `F` | Follow mode: preview sessions as you move |
| `D` / `S` | Dashboard · sidebar |
| `g` (`gr` in evil) | Refresh (clears the git cache) |
| `q` | Close the sidebar or quit the dashboard |
| `?` | All actions |

## Status

| Icon | Meaning |
|---|---|
| `◐` | Working (with a live "Working for 12s") |
| `◉` | Waiting on a permission or question |
| `✔` | Finished while you weren't looking, until you visit it |
| `●` | Idle |
| `○` | Starting |
| `✕` | Error or exited |

When a session needs permission, finishes, or errors while you're not looking at it, you get a
desktop notification. It uses `alert` if installed, then `osascript` on macOS, then D-Bus on
Linux. The mode-line shows a clickable counter like ` ◉1 ◐2 `: left-click jumps to the next
agent that needs you, right-click toggles the sidebar.

## Options

| Variable | Default | |
|---|---|---|
| `agent-shell-pod-project-sources` | `(open sessions)` | Add `known` to list every `project-known-project-roots` entry |
| `agent-shell-pod-worktree-policy` | `ask` | `ask`, `always` or `never` |
| `agent-shell-pod-branch-prefix` | `"agent/"` | Suggested branch prefix |
| `agent-shell-pod-worktree-directory-function` | under `.agent-shell/worktrees/` | Same place as `agent-shell-new-worktree-shell` |
| `agent-shell-pod-show-idle-worktrees` | `t` | List worktrees without agents |
| `agent-shell-pod-notify-statuses` | `(waiting finished error)` | |
| `agent-shell-pod-notify-function` | `agent-shell-pod-notify-desktop` | `(title body buffer)` |
| `agent-shell-pod-mode-line-statuses` | `(waiting finished working)` | |
| `agent-shell-pod-sidebar-width` / `-side` | `38` / `left` | |
| `agent-shell-pod-session-display` | `main-window` | Or `side-window` |
| `agent-shell-pod-setup-keys` | `t` | Evil and Doom bindings when the mode turns on |
| `agent-shell-pod-leader-key` / `-localleader-key` | `"l"` / `"l"` | Doom only; nil to skip |
| `agent-shell-pod-session-side` / `-width` | `right` / `0.4` | For `side-window` |
| `agent-shell-pod-status-icons` | see above | |

Faces are in the `agent-shell-pod` customization group.

## Remote access (Telegram)

Leave Emacs running and keep working from your phone: read replies, approve permissions, send
prompts and switch sessions through a Telegram bot. It long-polls Telegram with `url.el`, so you
don't need a public URL or any extra package.

1. Message [@BotFather](https://t.me/BotFather), send `/newbot` and copy the token.
2. Put the token in `~/.authinfo.gpg`:
   ```
   machine api.telegram.org password 123456:ABC-your-token
   ```
3. Get your numeric user id from [@userinfobot](https://t.me/userinfobot), then:
   ```elisp
   (require 'agent-shell-pod-telegram)
   (setq agent-shell-pod-telegram-user-id 123456789)
   (agent-shell-pod-telegram-mode 1)
   ```
4. Open a chat with your bot and send `/list`.

The bot only answers that one user id. If the id isn't set, the mode won't start. Every message
starts with a tag like `[2 Fix login · acme-web]`. Permission requests arrive with a button for each
option, and the usual Emacs prompt still shows. Whichever one you answer first wins, and the other
gets cleared.

| Message | Action |
|---|---|
| text | Prompt the current session, or queue it if the agent is busy |
| reply to a bot message | Prompt that message's session |
| `/list` | Sessions with number, status, title and project |
| `/use N` | Make session N current |
| `/stop [N]` | Interrupt the session |
| `/new [N]` | Start an agent in session N's directory. Needs `agent-shell-preferred-agent-config` |
| `/last [N]` | Resend the session's last reply |

Set `agent-shell-pod-telegram-only-when-away` to `t` to get replies and permission prompts only
for sessions you're not looking at in Emacs.

Anyone who controls this bot can run commands on your machine through the agent. Keep the token
secret, and remember that bot chats aren't end-to-end encrypted. Emacs has to stay awake for this
to work. On macOS you can run `caffeinate -i` to keep it awake.

## How it works

- Sessions come from `agent-shell-buffers`, and status from `agent-shell-status` plus
  `agent-shell-subscribe-to` events (`input-submitted`, `permission-request`, `turn-complete`,
  `error`). It doesn't parse buffer text.
- Projects come from `project-current`. Git worktrees resolve to their main checkout through
  `git rev-parse --git-common-dir`, so a worktree under `.agent-shell/worktrees/` shows up under
  its parent repo rather than as a separate project.
- Git lookups are cached for `agent-shell-pod-git-cache-ttl` seconds. Redraws are debounced and
  only happen while the sidebar or dashboard is visible.

## Tests

```sh
emacs -Q --batch -L path/to/shell-maker -L path/to/acp.el -L path/to/agent-shell -L . \
  -l agent-shell-pod-test.el -l agent-shell-pod-telegram-test.el -f ert-run-tests-batch-and-exit
```
