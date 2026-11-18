;;; agent-shell-pod.el --- Orca-style sidebar and dashboard for agent-shell -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.24.2"))
;; Keywords: tools, convenience, processes

;; This file is not part of GNU Emacs.

;;; Commentary:

;; An Orca-style sidebar and dashboard for agent-shell sessions,
;; grouped by project.el project and git worktree.  See README.md.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)
(require 'project)
(require 'transient)
(require 'agent-shell)

(declare-function agent-shell-viewport--shell-buffer "agent-shell-viewport")
(declare-function agent-shell-worktree--generate-name "agent-shell-worktree")
(declare-function agent-shell--dot-subdir "agent-shell")
(declare-function agent-shell--auto-preferred-config "agent-shell")
(declare-function agent-shell-jump-to-latest-permission-button-row "agent-shell")
(declare-function agent-shell-set-session-mode "agent-shell")
(declare-function agent-shell-set-session-model "agent-shell")
(declare-function agent-shell-restart "agent-shell")
(declare-function magit-status-setup-buffer "magit-status")
(declare-function notifications-notify "notifications")
(declare-function alert "alert")
(declare-function evil-define-key* "evil-core")
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-normalize-keymaps "evil-core")
(declare-function projectile-project-root "projectile")
(defvar projectile-known-projects)

(defgroup agent-shell-pod nil
  "Sidebar and dashboard for agent-shell sessions, grouped by project."
  :group 'agent-shell
  :prefix "agent-shell-pod-")

(defcustom agent-shell-pod-sidebar-width 38
  "Width of the sidebar window in columns."
  :type 'natnum)

(defcustom agent-shell-pod-sidebar-side 'left
  "Frame side where the sidebar is displayed."
  :type '(choice (const left) (const right)))

(defcustom agent-shell-pod-project-sources '(open sessions)
  "Where the list of projects comes from.
`open' lists projects with at least one visiting buffer.
`sessions' lists projects that have an agent session.
`known' lists everything in `project-known-project-roots'."
  :type '(set (const open) (const sessions) (const known)))

(defcustom agent-shell-pod-project-buffer-predicate
  #'agent-shell-pod-default-project-buffer-p
  "Predicate deciding whether a buffer makes its project count as open."
  :type 'function)

(defcustom agent-shell-pod-read-project-function #'agent-shell-pod-read-project-dir
  "Function that prompts for a project and returns its directory."
  :type 'function)

(defcustom agent-shell-pod-worktree-policy 'ask
  "What to do about git worktrees when starting a session in a project.
`ask' prompts each time, `always' creates a new worktree and
`never' starts in the current checkout."
  :type '(choice (const ask) (const always) (const never)))

(defcustom agent-shell-pod-branch-prefix "agent/"
  "Prefix for branch names suggested when creating a worktree."
  :type 'string)

(defcustom agent-shell-pod-worktree-directory-function
  #'agent-shell-pod-default-worktree-directory
  "Function of (ROOT NAME) returning the directory for a new worktree."
  :type 'function)

(defcustom agent-shell-pod-show-idle-worktrees t
  "When non-nil, list git worktrees that have no agent session."
  :type 'boolean)

(defcustom agent-shell-pod-show-status-line t
  "When non-nil, show a status line under busy or finished sessions."
  :type 'boolean)

(defcustom agent-shell-pod-status-icons
  '((working . "◐")
    (waiting . "◉")
    (finished . "✔")
    (ready . "●")
    (initializing . "○")
    (error . "✕")
    (killed . "✕"))
  "Icons for each session status."
  :type '(alist :key-type symbol :value-type string))

(defcustom agent-shell-pod-notify-statuses '(waiting finished error)
  "Statuses that trigger a notification when you are not looking."
  :type '(set (const waiting) (const finished) (const error)))

(defcustom agent-shell-pod-notify-function #'agent-shell-pod-notify-desktop
  "Function of (TITLE BODY BUFFER) used to send notifications."
  :type 'function)

(defcustom agent-shell-pod-mode-line-statuses '(waiting finished working)
  "Statuses counted in the global mode-line indicator."
  :type '(set (const waiting) (const finished) (const working) (const error)))

(defcustom agent-shell-pod-git-cache-ttl 15
  "Seconds to cache git and project lookups."
  :type 'number)

(defcustom agent-shell-pod-tick-interval 1
  "Seconds between redraws while an agent is working."
  :type 'number)

(defcustom agent-shell-pod-hide-sidebar-mode-line t
  "When non-nil, the sidebar window has no mode line."
  :type 'boolean)

(defcustom agent-shell-pod-session-display 'main-window
  "Where agent sessions are shown.
`main-window' puts the agent in the most recently used window.
`side-window' shows it in a side window next to your code."
  :type '(choice (const main-window) (const side-window)))

(defcustom agent-shell-pod-session-side 'right
  "Frame side for agents when `agent-shell-pod-session-display' is `side-window'."
  :type '(choice (const right) (const left) (const bottom)))

(defcustom agent-shell-pod-session-width 0.4
  "Width of the agent side window, in columns or as a fraction of the frame."
  :type 'number)

(defcustom agent-shell-pod-setup-keys t
  "When non-nil, `agent-shell-pod-mode' sets up key bindings.
With evil, the sidebar and dashboard get normal-state keys.  In Doom
Emacs, `agent-shell-pod-leader-key' and
`agent-shell-pod-localleader-key' are bound too."
  :type 'boolean)

(defcustom agent-shell-pod-leader-key "l"
  "Doom leader key for `agent-shell-pod-menu', or nil for none."
  :type '(choice (const :tag "None" nil) string))

(defcustom agent-shell-pod-localleader-key "l"
  "Doom localleader key for `agent-shell-pod-session-menu', or nil for none.
It is bound in agent-shell buffers."
  :type '(choice (const :tag "None" nil) string))

(defface agent-shell-pod-project '((t :inherit bold))
  "Face for project names.")

(defface agent-shell-pod-branch '((t :inherit font-lock-function-name-face))
  "Face for worktree branch names.")

(defface agent-shell-pod-meta '((t :inherit shadow))
  "Face for secondary details.")

(defface agent-shell-pod-title '((t :inherit default))
  "Face for session titles.")

(defface agent-shell-pod-action '((t :inherit (shadow italic)))
  "Face for action lines such as New agent.")

(defface agent-shell-pod-current '((t :inherit font-lock-keyword-face))
  "Face for the marker of the session shown in the main window.")

(defface agent-shell-pod-working '((t :inherit warning))
  "Face for working sessions.")

(defface agent-shell-pod-waiting '((t :inherit error :weight bold))
  "Face for sessions waiting on you.")

(defface agent-shell-pod-finished
  '((((background dark)) :foreground "#5fd7d7")
    (t :foreground "#008b8b"))
  "Face for sessions that finished while you were away.")

(defface agent-shell-pod-ready '((t :inherit success))
  "Face for idle sessions.")

(defface agent-shell-pod-inactive '((t :inherit shadow))
  "Face for starting or exited sessions.")

(defface agent-shell-pod-error '((t :inherit error))
  "Face for sessions that hit an error.")

(defconst agent-shell-pod--sidebar-name "*agent-pod*")
(defconst agent-shell-pod--dashboard-name "*agent-pod: dashboard*")

(defvar agent-shell-pod--cache (make-hash-table :test 'equal))
(defvar agent-shell-pod--folded (make-hash-table :test 'equal))
(defvar agent-shell-pod--extra-roots nil)
(defvar agent-shell-pod--hidden-roots nil)
(defvar agent-shell-pod--refresh-timer nil)
(defvar agent-shell-pod--tick-timer nil)
(defvar agent-shell-pod--counts nil)
(defvar agent-shell-pod-event-functions nil
  "Functions called with each agent-shell event, in the session buffer.")

(defvar-local agent-shell-pod--subscription nil)
(defvar-local agent-shell-pod--created nil)
(defvar-local agent-shell-pod--busy-since nil)
(defvar-local agent-shell-pod--last-duration nil)
(defvar-local agent-shell-pod--last-activity nil)
(defvar-local agent-shell-pod--finished nil)
(defvar-local agent-shell-pod--error nil)
(defvar-local agent-shell-pod--label nil)
(defvar-local agent-shell-pod--follow-last nil)

(defun agent-shell-pod--session-p (buffer)
  "Return non-nil when BUFFER is a live agent-shell buffer."
  (and (bufferp buffer)
       (buffer-live-p buffer)
       (with-current-buffer buffer (derived-mode-p 'agent-shell-mode))))

(defun agent-shell-pod--sessions ()
  "Return live agent-shell buffers, most recently used first."
  (seq-filter #'agent-shell-pod--session-p (agent-shell-buffers)))

(defun agent-shell-pod--shell-of (buffer)
  "Return the shell buffer behind BUFFER, which may be a viewport."
  (cond ((agent-shell-pod--session-p buffer) buffer)
        ((and (buffer-live-p buffer)
              (fboundp 'agent-shell-viewport--shell-buffer))
         (ignore-errors (agent-shell-viewport--shell-buffer buffer)))))

(defun agent-shell-pod--cached (key fn)
  "Return the cached value for KEY, computing it with FN when stale."
  (let ((hit (gethash key agent-shell-pod--cache)))
    (if (and hit (< (- (float-time) (car hit)) agent-shell-pod-git-cache-ttl))
        (cdr hit)
      (let ((value (funcall fn)))
        (puthash key (cons (float-time) value) agent-shell-pod--cache)
        value))))

(defun agent-shell-pod--dir (dir)
  "Return DIR expanded, with a trailing slash."
  (file-name-as-directory (expand-file-name dir)))

(defun agent-shell-pod--git (dir &rest args)
  "Run git with ARGS in DIR and return trimmed output, or nil on failure."
  (unless (file-remote-p dir)
    (let ((default-directory (agent-shell-pod--dir dir)))
      (with-temp-buffer
        (when (eq 0 (ignore-errors (apply #'process-file "git" nil t nil args)))
          (string-trim-right (buffer-string)))))))

(defun agent-shell-pod--git-or-error (dir &rest args)
  "Run git with ARGS in DIR, signalling a `user-error' on failure."
  (let ((default-directory (agent-shell-pod--dir dir)))
    (with-temp-buffer
      (let ((code (apply #'process-file "git" nil t nil args)))
        (unless (eq code 0)
          (user-error "Git %s failed: %s" (car args) (string-trim (buffer-string))))
        (string-trim-right (buffer-string))))))

(defun agent-shell-pod--git-info (dir)
  "Return a plist describing the git checkout containing DIR, or nil."
  (agent-shell-pod--cached
   (list 'info dir)
   (lambda ()
     (when-let* ((out (agent-shell-pod--git
                       dir "rev-parse" "--path-format=absolute"
                       "--show-toplevel" "--git-common-dir"
                       "--abbrev-ref" "HEAD"))
                 (lines (split-string out "\n" t))
                 ((= (length lines) 3)))
       (let* ((top (agent-shell-pod--dir (nth 0 lines)))
              (common (directory-file-name (nth 1 lines)))
              (main (if (equal (file-name-nondirectory common) ".git")
                        (agent-shell-pod--dir (file-name-directory common))
                      top))
              (branch (nth 2 lines)))
         (list :toplevel top
               :main main
               :branch (if (equal branch "HEAD") "detached" branch)
               :primary (equal top main)))))))

(defun agent-shell-pod--root-for (dir)
  "Return the project root that DIR belongs to.
Git worktrees resolve to their main checkout so they group together."
  (when (and (stringp dir) (not (file-remote-p dir)))
    (let ((dir (agent-shell-pod--dir dir)))
      (agent-shell-pod--cached
       (list 'root dir)
       (lambda ()
         (when-let* ((found (or (when-let* ((project (ignore-errors (project-current nil dir))))
                                  (project-root project))
                                (and (bound-and-true-p projectile-mode)
                                     (ignore-errors (projectile-project-root dir)))))
                     (root (agent-shell-pod--dir found)))
           (or (plist-get (agent-shell-pod--git-info root) :main) root)))))))

(defun agent-shell-pod--project-name (root)
  "Return the display name of the project at ROOT."
  (agent-shell-pod--cached
   (list 'name root)
   (lambda ()
     (or (when-let* ((project (ignore-errors (project-current nil root))))
           (ignore-errors (project-name project)))
         (file-name-nondirectory (directory-file-name root))))))

(defun agent-shell-pod--worktrees (root)
  "Return git worktrees of ROOT as plists, primary first."
  (agent-shell-pod--cached
   (list 'worktrees root)
   (lambda ()
     (when-let* ((out (agent-shell-pod--git root "worktree" "list" "--porcelain")))
       (let (result)
         (dolist (block (split-string out "\n\n" t))
           (let (path branch bare)
             (dolist (line (split-string block "\n" t))
               (cond ((string-prefix-p "worktree " line)
                      (setq path (agent-shell-pod--dir (substring line 9))))
                     ((string-prefix-p "branch refs/heads/" line)
                      (setq branch (substring line 18)))
                     ((equal line "bare") (setq bare t))))
             (when (and path (not bare))
               (push (list :toplevel path
                           :branch (or branch "detached")
                           :primary (equal path (agent-shell-pod--dir root)))
                     result))))
         (nreverse result))))))

(defun agent-shell-pod-default-project-buffer-p (buffer)
  "Return non-nil when BUFFER visits a file or directory."
  (and (not (string-prefix-p " " (buffer-name buffer)))
       (or (buffer-file-name buffer)
           (with-current-buffer buffer (derived-mode-p 'dired-mode)))))

(defun agent-shell-pod-default-worktree-directory (root name)
  "Return the directory for worktree NAME of the project at ROOT."
  (let ((default-directory root))
    (expand-file-name
     name
     (if (fboundp 'agent-shell--dot-subdir)
         (agent-shell--dot-subdir "worktrees")
       (expand-file-name ".agent-shell/worktrees" root)))))

(defun agent-shell-pod--open-roots ()
  "Return project roots that have an open buffer."
  (let ((dirs (make-hash-table :test 'equal))
        roots)
    (dolist (buffer (buffer-list))
      (let ((dir (buffer-local-value 'default-directory buffer)))
        (when (and (stringp dir)
                   (not (file-remote-p dir))
                   (funcall agent-shell-pod-project-buffer-predicate buffer))
          (puthash dir t dirs))))
    (maphash (lambda (dir _)
               (when-let* ((root (agent-shell-pod--root-for dir)))
                 (cl-pushnew root roots :test #'equal)))
             dirs)
    roots))

(defun agent-shell-pod--state (buffer)
  "Return the agent-shell state of BUFFER."
  (buffer-local-value 'agent-shell--state buffer))

(defun agent-shell-pod--status (buffer)
  "Return the status symbol of session BUFFER."
  (with-current-buffer buffer
    (let* ((state agent-shell--state)
           (comint (get-buffer-process buffer))
           (acp (map-nested-elt state '(:client :process))))
      (cond
       ((or (not (process-live-p comint))
            (and (processp acp) (not (process-live-p acp))))
        'killed)
       ((not (map-nested-elt state '(:session :id))) 'initializing)
       (t
        (pcase (ignore-errors (agent-shell-status :shell-buffer buffer))
          ('blocked 'waiting)
          ('busy 'working)
          (_ (cond (agent-shell-pod--error 'error)
                   (agent-shell-pod--finished 'finished)
                   (t 'ready)))))))))

(defun agent-shell-pod--format-duration (seconds)
  "Format SECONDS as a short duration."
  (let ((s (max 0 (round seconds))))
    (cond ((< s 60) (format "%ds" s))
          ((< s 3600) (format "%dm %ds" (/ s 60) (% s 60)))
          (t (format "%dh %dm" (/ s 3600) (/ (% s 3600) 60))))))

(defun agent-shell-pod--format-ago (time)
  "Format TIME as a short relative age."
  (if (not time)
      ""
    (let ((s (round (- (float-time) time))))
      (cond ((< s 60) "now")
            ((< s 3600) (format "%dm" (/ s 60)))
            ((< s 86400) (format "%dh" (/ s 3600)))
            (t (format "%dd" (/ s 86400)))))))

(defun agent-shell-pod--title (buffer)
  "Return the display title of session BUFFER."
  (let* ((state (agent-shell-pod--state buffer))
         (title (or (buffer-local-value 'agent-shell-pod--label buffer)
                    (map-nested-elt state '(:session :title))
                    "New session")))
    (string-trim (replace-regexp-in-string "[\n\r\t ]+" " " title))))

(defun agent-shell-pod--agent-name (buffer)
  "Return the agent name of session BUFFER."
  (let ((config (map-elt (agent-shell-pod--state buffer) :agent-config)))
    (or (map-elt config :mode-line-name)
        (map-elt config :buffer-name)
        "Agent")))

(defun agent-shell-pod--model (buffer)
  "Return the model name of session BUFFER, or nil."
  (ignore-errors (agent-shell-get-model-name (agent-shell-pod--state buffer))))

(defun agent-shell-pod--usage (buffer)
  "Return (CONTEXT-PERCENT COST CURRENCY) for session BUFFER."
  (let* ((usage (map-elt (agent-shell-pod--state buffer) :usage))
         (used (or (map-elt usage :context-used) 0))
         (size (or (map-elt usage :context-size) 0))
         (cost (or (map-elt usage :cost-amount) 0)))
    (list (when (> size 0) (round (* 100.0 (/ (float used) size))))
          (when (and (numberp cost) (> cost 0)) cost)
          (map-elt usage :cost-currency))))

(defun agent-shell-pod--status-text (info)
  "Return the status line text for session INFO."
  (pcase (plist-get info :status)
    ('working (format "Working for %s"
                      (agent-shell-pod--format-duration
                       (- (float-time) (or (plist-get info :busy-since) (float-time))))))
    ('waiting "Needs your input")
    ('finished (if-let* ((d (plist-get info :duration)))
                   (format "Worked for %s" (agent-shell-pod--format-duration d))
                 "Finished"))
    ('error (format "Error: %s" (or (plist-get info :error) "request failed")))
    ('initializing "Starting…")
    ('killed "Exited")
    (_ nil)))

(defun agent-shell-pod--session-info (buffer)
  "Return a plist describing session BUFFER."
  (let* ((dir (agent-shell-pod--dir (buffer-local-value 'default-directory buffer)))
         (git (agent-shell-pod--git-info dir))
         (status (agent-shell-pod--status buffer))
         (usage (agent-shell-pod--usage buffer)))
    (with-current-buffer buffer
      (when (and (eq status 'working) (not agent-shell-pod--busy-since))
        (setq agent-shell-pod--busy-since (float-time))))
    (list :type 'session
          :buffer buffer
          :status status
          :dir dir
          :root (or (agent-shell-pod--root-for dir) dir)
          :toplevel (or (plist-get git :toplevel) dir)
          :branch (plist-get git :branch)
          :primary (plist-get git :primary)
          :title (agent-shell-pod--title buffer)
          :agent (agent-shell-pod--agent-name buffer)
          :model (agent-shell-pod--model buffer)
          :context (nth 0 usage)
          :cost (nth 1 usage)
          :currency (nth 2 usage)
          :busy-since (buffer-local-value 'agent-shell-pod--busy-since buffer)
          :duration (buffer-local-value 'agent-shell-pod--last-duration buffer)
          :activity (buffer-local-value 'agent-shell-pod--last-activity buffer)
          :error (buffer-local-value 'agent-shell-pod--error buffer)
          :created (or (buffer-local-value 'agent-shell-pod--created buffer) 0))))

(defun agent-shell-pod--collect ()
  "Return the project tree: a list of project plists."
  (let* ((sessions (mapcar #'agent-shell-pod--session-info (agent-shell-pod--sessions)))
         (roots (append
                 (when (memq 'open agent-shell-pod-project-sources)
                   (agent-shell-pod--open-roots))
                 (when (memq 'known agent-shell-pod-project-sources)
                   (delq nil (mapcar #'agent-shell-pod--root-for
                                     (append (project-known-project-roots)
                                             (bound-and-true-p projectile-known-projects)))))
                 agent-shell-pod--extra-roots))
         (with-sessions (delete-dups (mapcar (lambda (s) (plist-get s :root)) sessions)))
         (roots (delete-dups
                 (append (when (memq 'sessions agent-shell-pod-project-sources) with-sessions)
                         (seq-remove (lambda (r) (member r agent-shell-pod--hidden-roots))
                                     roots)
                         (seq-filter (lambda (r) (member r agent-shell-pod--hidden-roots))
                                     with-sessions))))
         projects)
    (dolist (root roots)
      (let ((table (make-hash-table :test 'equal))
            (order nil)
            (mine (seq-filter (lambda (s) (equal (plist-get s :root) root)) sessions)))
        (when agent-shell-pod-show-idle-worktrees
          (dolist (wt (agent-shell-pod--worktrees root))
            (let ((key (plist-get wt :toplevel)))
              (puthash key (list :type 'worktree :root root :toplevel key
                                 :branch (plist-get wt :branch)
                                 :primary (plist-get wt :primary)
                                 :sessions nil)
                       table)
              (push key order))))
        (dolist (s (sort (copy-sequence mine)
                         (lambda (a b) (< (plist-get a :created) (plist-get b :created)))))
          (let* ((key (plist-get s :toplevel))
                 (wt (or (gethash key table)
                         (progn
                           (push key order)
                           (list :type 'worktree :root root :toplevel key
                                 :branch (plist-get s :branch)
                                 :primary (plist-get s :primary)
                                 :sessions nil)))))
            (puthash key (plist-put wt :sessions
                                    (append (plist-get wt :sessions) (list s)))
                     table)))
        (let ((worktrees (mapcar (lambda (k) (gethash k table)) (nreverse order))))
          (setq worktrees
                (sort worktrees
                      (lambda (a b)
                        (cond ((plist-get a :primary) (not (plist-get b :primary)))
                              ((plist-get b :primary) nil)
                              (t (string< (or (plist-get a :branch) "")
                                          (or (plist-get b :branch) "")))))))
          (push (list :type 'project
                      :root root
                      :name (agent-shell-pod--project-name root)
                      :worktrees worktrees
                      :sessions mine
                      :git (seq-some (lambda (w) (plist-get w :branch)) worktrees))
                projects))))
    (sort projects (lambda (a b) (string< (downcase (plist-get a :name))
                                          (downcase (plist-get b :name)))))))

(defun agent-shell-pod--icon (status)
  "Return the propertized icon for STATUS."
  (propertize (or (alist-get status agent-shell-pod-status-icons) "?")
              'face (agent-shell-pod--status-face status)))

(defun agent-shell-pod--status-face (status)
  "Return the face for STATUS."
  (pcase status
    ('working 'agent-shell-pod-working)
    ('waiting 'agent-shell-pod-waiting)
    ('finished 'agent-shell-pod-finished)
    ('ready 'agent-shell-pod-ready)
    ('error 'agent-shell-pod-error)
    (_ 'agent-shell-pod-inactive)))

(defun agent-shell-pod--attention-p (status)
  "Return non-nil when STATUS needs the user."
  (memq status '(waiting finished error)))

(defun agent-shell-pod--fold-key (item)
  "Return the fold key for ITEM."
  (pcase (plist-get item :type)
    ('project (list 'project (plist-get item :root)))
    ('worktree (list 'worktree (plist-get item :toplevel)))))

(defun agent-shell-pod--folded-p (item)
  "Return non-nil when ITEM is folded."
  (let ((v (gethash (agent-shell-pod--fold-key item) agent-shell-pod--folded 'unset)))
    (if (eq v 'unset)
        (and (eq (plist-get item :type) 'project)
             (null (plist-get item :sessions)))
      v)))

(defun agent-shell-pod--item-key (item)
  "Return a stable identity for ITEM."
  (when item
    (pcase (plist-get item :type)
      ('session (list 'session (plist-get item :buffer)))
      ('new (list 'new (plist-get item :root) (plist-get item :toplevel)))
      (_ (agent-shell-pod--fold-key item)))))

(defun agent-shell-pod--item-at (&optional pos)
  "Return the item at POS."
  (get-text-property (or pos (point)) 'agent-shell-pod-item))

(defun agent-shell-pod--insert-line (item text)
  "Insert TEXT as one line belonging to ITEM."
  (let ((start (point)))
    (insert text "\n")
    (when item
      (add-text-properties start (point)
                           (list 'agent-shell-pod-item item
                                 'mouse-face 'highlight
                                 'help-echo "mouse-1: visit")))))

(defun agent-shell-pod--fit (left right width)
  "Return LEFT and RIGHT laid out on one line of WIDTH columns."
  (let* ((right (or right ""))
         (rw (string-width right))
         (room (max 4 (- width rw (if (> rw 0) 1 0))))
         (left (truncate-string-to-width left room nil nil "…")))
    (if (zerop rw)
        left
      (concat left
              (propertize " " 'display `(space :align-to ,(- width rw)))
              right))))

(defun agent-shell-pod--windows-by-use ()
  "Return the frame's windows, most recently used first."
  (sort (window-list nil 'nomini)
        (lambda (a b) (> (window-use-time a) (window-use-time b)))))

(defun agent-shell-pod--visible-session ()
  "Return the most recently used session shown in a window."
  (seq-some (lambda (w) (agent-shell-pod--shell-of (window-buffer w)))
            (agent-shell-pod--windows-by-use)))

(defun agent-shell-pod--current-session ()
  "Return the session you are most likely looking at."
  (agent-shell-pod--visible-session))

(defun agent-shell-pod--render-sidebar (width)
  "Insert the sidebar contents for a window WIDTH columns wide."
  (let ((current (agent-shell-pod--current-session))
        (projects (agent-shell-pod--collect)))
    (unless projects
      (insert (propertize "\n  No open projects.\n  Press + to add one.\n"
                          'face 'agent-shell-pod-meta)))
    (dolist (p projects)
      (let* ((folded (agent-shell-pod--folded-p p))
             (sessions (plist-get p :sessions))
             (attention (seq-count (lambda (s) (agent-shell-pod--attention-p
                                                (plist-get s :status)))
                                   sessions))
             (right (concat
                     (if (> attention 0)
                         (propertize (format "◉%d " attention) 'face 'agent-shell-pod-waiting)
                       "")
                     (propertize (if sessions (number-to-string (length sessions)) "")
                                 'face 'agent-shell-pod-meta))))
        (agent-shell-pod--insert-line
         p (agent-shell-pod--fit
            (concat " " (propertize (if folded "▸ " "▾ ") 'face 'agent-shell-pod-meta)
                    (propertize (plist-get p :name) 'face 'agent-shell-pod-project))
            right width))
        (unless folded
          (dolist (wt (plist-get p :worktrees))
            (let ((indent (if (plist-get p :git) "     " "   "))
                  (wt-folded (and (plist-get p :git) (agent-shell-pod--folded-p wt)))
                  (wt-sessions (plist-get wt :sessions)))
              (when (plist-get p :git)
                (agent-shell-pod--insert-line
                 wt (agent-shell-pod--fit
                     (concat "   "
                             (propertize (cond ((null wt-sessions) "  ")
                                               (wt-folded "▸ ")
                                               (t "▾ "))
                                         'face 'agent-shell-pod-meta)
                             (propertize (or (plist-get wt :branch) "?")
                                         'face (if wt-sessions
                                                   'agent-shell-pod-branch
                                                 'agent-shell-pod-meta)))
                     (cond ((plist-get wt :primary)
                            (propertize "primary" 'face 'agent-shell-pod-meta))
                           ((and wt-folded wt-sessions)
                            (propertize (number-to-string (length wt-sessions))
                                        'face 'agent-shell-pod-meta)))
                     width)))
              (unless wt-folded
                (dolist (s wt-sessions)
                  (let* ((buffer (plist-get s :buffer))
                         (status (plist-get s :status))
                         (marker (if (eq buffer current)
                                     (propertize "▌" 'face 'agent-shell-pod-current)
                                   " "))
                         (meta (propertize
                                (string-join
                                 (delq nil (list (when-let* ((m (or (plist-get s :model)
                                                                    (plist-get s :agent))))
                                                   (truncate-string-to-width m 12 nil nil "…"))
                                                 (agent-shell-pod--format-ago
                                                  (or (plist-get s :activity)
                                                      (plist-get s :created)))))
                                 " ")
                                'face 'agent-shell-pod-meta)))
                    (agent-shell-pod--insert-line
                     s (agent-shell-pod--fit
                        (concat marker (substring indent 1)
                                (agent-shell-pod--icon status) " "
                                (propertize (plist-get s :title) 'face 'agent-shell-pod-title))
                        meta width))
                    (when-let* ((agent-shell-pod-show-status-line)
                                ((not (eq status 'ready)))
                                (text (agent-shell-pod--status-text s)))
                      (agent-shell-pod--insert-line
                       s (agent-shell-pod--fit
                          (concat indent "  "
                                  (propertize text 'face (agent-shell-pod--status-face status)))
                          nil width))))))))
          (agent-shell-pod--insert-line
           (list :type 'new :root (plist-get p :root))
           (propertize "   + New agent" 'face 'agent-shell-pod-action)))))
    (agent-shell-pod--insert-footer (or current (car (agent-shell-pod--sessions))) width)))

(defun agent-shell-pod--insert-footer (current width)
  "Insert the usage footer for CURRENT session in WIDTH columns."
  (let* ((usage (and current (agent-shell-pod--usage current)))
         (pct (nth 0 usage))
         (total 0.0)
         currency)
    (dolist (b (agent-shell-pod--sessions))
      (pcase-let ((`(,_ ,cost ,cur) (agent-shell-pod--usage b)))
        (when cost
          (setq total (+ total cost)
                currency (or currency cur)))))
    (when (or pct (> total 0))
      (insert "\n" (propertize (concat " " (make-string (max 1 (- width 2)) ?─))
                               'face 'agent-shell-pod-meta)
              "\n")
      (when pct
        (let* ((cells 10)
               (filled (min cells (round (* cells (/ pct 100.0))))))
          (insert (propertize " ctx  " 'face 'agent-shell-pod-meta)
                  (propertize (make-string filled ?█)
                              'face (cond ((>= pct 85) 'agent-shell-pod-waiting)
                                          ((>= pct 60) 'agent-shell-pod-working)
                                          (t 'agent-shell-pod-ready)))
                  (propertize (make-string (- cells filled) ?░) 'face 'agent-shell-pod-meta)
                  (propertize (format " %d%%" pct) 'face 'agent-shell-pod-meta)
                  "\n")))
      (when (> total 0)
        (insert (propertize (format " cost %s%.2f all sessions\n"
                                    (if (member currency '(nil "USD")) "$"
                                      (concat currency " "))
                                    total)
                            'face 'agent-shell-pod-meta))))))

(defun agent-shell-pod--pad (string width)
  "Truncate or pad STRING to WIDTH columns."
  (truncate-string-to-width (or string "") width nil ?\s "…"))

(defun agent-shell-pod--render-dashboard (width)
  "Insert the dashboard contents for a window WIDTH columns wide."
  (let* ((projects (agent-shell-pod--collect))
         (all (seq-mapcat (lambda (p) (plist-get p :sessions)) projects))
         (queue (agent-shell-pod--attention-queue))
         (attention (sort (seq-filter (lambda (s) (memq (plist-get s :buffer) queue)) all)
                          (lambda (a b) (< (length (memq (plist-get b :buffer) queue))
                                           (length (memq (plist-get a :buffer) queue))))))
         (show-agent (>= width 118))
         (show-usage (>= width 96))
         (title-width (max 14 (min 40 (- width 3 2 23 21
                                          (if show-agent 25 0)
                                          (if show-usage 16 0)))))
         (needs-title-width (max 14 (min 40 (- width 3 2 17 23 21)))))
    (insert "\n")
    (when attention
      (insert (propertize (format " Needs you (%d)\n" (length attention))
                          'face 'agent-shell-pod-waiting))
      (dolist (s attention)
        (agent-shell-pod--insert-line
         s (concat "   " (agent-shell-pod--icon (plist-get s :status)) " "
                   (agent-shell-pod--pad (agent-shell-pod--project-name (plist-get s :root)) 16) " "
                   (propertize (agent-shell-pod--pad (or (plist-get s :branch) "") 22)
                               'face 'agent-shell-pod-branch)
                   " "
                   (agent-shell-pod--pad (plist-get s :title) needs-title-width) " "
                   (propertize (or (agent-shell-pod--status-text s) "")
                               'face (agent-shell-pod--status-face (plist-get s :status))))))
      (insert "\n"))
    (unless projects
      (insert (propertize " No open projects. Press + to add one.\n" 'face 'agent-shell-pod-meta)))
    (dolist (p projects)
      (let ((folded (agent-shell-pod--folded-p p))
            (sessions (plist-get p :sessions)))
        (agent-shell-pod--insert-line
         p (concat " " (propertize (if folded "▸ " "▾ ") 'face 'agent-shell-pod-meta)
                   (propertize (agent-shell-pod--pad (plist-get p :name) 18)
                               'face 'agent-shell-pod-project)
                   " "
                   (propertize (agent-shell-pod--pad (abbreviate-file-name (plist-get p :root))
                                                     (max 10 (min 40 (- width 50))))
                               'face 'agent-shell-pod-meta)
                   " "
                   (propertize (pcase (length sessions)
                                 (0 "no sessions")
                                 (1 "1 session")
                                 (n (format "%d sessions" n)))
                               'face 'agent-shell-pod-meta)))
        (unless folded
          (dolist (s (seq-mapcat (lambda (w) (plist-get w :sessions)) (plist-get p :worktrees)))
            (pcase-let* ((status (plist-get s :status))
                         (ctx (plist-get s :context))
                         (cost (plist-get s :cost)))
              (agent-shell-pod--insert-line
               s (concat "   " (agent-shell-pod--icon status) " "
                         (propertize (agent-shell-pod--pad (or (plist-get s :branch)
                                                               (abbreviate-file-name (plist-get s :dir)))
                                                           22)
                                     'face 'agent-shell-pod-branch)
                         " "
                         (agent-shell-pod--pad (plist-get s :title) title-width) " "
                         (if show-agent
                             (concat
                              (propertize (agent-shell-pod--pad
                                           (string-join (delq nil (list (plist-get s :agent)
                                                                        (plist-get s :model)))
                                                        " · ")
                                           24)
                                          'face 'agent-shell-pod-meta)
                              " ")
                           "")
                         (propertize (agent-shell-pod--pad
                                      (or (agent-shell-pod--status-text s)
                                          (format "Idle %s" (agent-shell-pod--format-ago
                                                             (or (plist-get s :activity)
                                                                 (plist-get s :created)))))
                                      20)
                                     'face (agent-shell-pod--status-face status))
                         " "
                         (if show-usage
                             (concat
                              (propertize (agent-shell-pod--pad (if ctx (format "ctx %d%%" ctx) "") 9)
                                          'face 'agent-shell-pod-meta)
                              (propertize (if cost (format "$%.2f" cost) "")
                                          'face 'agent-shell-pod-meta))
                           "")))))
          (agent-shell-pod--insert-line
           (list :type 'new :root (plist-get p :root))
           (propertize "   + New agent" 'face 'agent-shell-pod-action)))
        (insert "\n")))))

(defun agent-shell-pod--find-key (key)
  "Return the position of the first line whose item has KEY."
  (save-excursion
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (not (eobp)))
        (when (equal (agent-shell-pod--item-key (agent-shell-pod--item-at)) key)
          (setq found (point)))
        (forward-line 1))
      found)))

(defun agent-shell-pod--redraw (buffer renderer)
  "Redraw BUFFER with RENDERER, keeping point on the same item."
  (with-current-buffer buffer
    (let* ((win (get-buffer-window buffer t))
           (width (if win (1- (window-body-width win)) agent-shell-pod-sidebar-width))
           (pt (if win (window-point win) (point)))
           (key (agent-shell-pod--item-key (agent-shell-pod--item-at pt)))
           (line (line-number-at-pos pt))
           (start-line (and win (line-number-at-pos (window-start win))))
           (inhibit-read-only t))
      (erase-buffer)
      (funcall renderer width)
      (goto-char (or (and key (agent-shell-pod--find-key key))
                     (progn (goto-char (point-min))
                            (forward-line (1- line))
                            (point))))
      (when win
        (set-window-point win (point))
        (set-window-start win (save-excursion
                                (goto-char (point-min))
                                (forward-line (1- start-line))
                                (point))
                          t)))))

(defun agent-shell-pod--visible-p (name)
  "Return the buffer NAME when it is displayed somewhere."
  (when-let* ((buffer (get-buffer name)))
    (and (get-buffer-window buffer t) buffer)))

(defun agent-shell-pod--update-counts ()
  "Recompute status counts for the mode line."
  (let (counts)
    (dolist (b (agent-shell-pod--sessions))
      (let ((status (agent-shell-pod--status b)))
        (setf (alist-get status counts) (1+ (alist-get status counts 0)))))
    (setq agent-shell-pod--counts counts)))

(defun agent-shell-pod--refresh ()
  "Redraw visible sidebars and dashboards and update the mode line."
  (setq agent-shell-pod--refresh-timer nil)
  (agent-shell-pod--update-counts)
  (when-let* ((buffer (agent-shell-pod--visible-p agent-shell-pod--sidebar-name)))
    (agent-shell-pod--redraw buffer #'agent-shell-pod--render-sidebar))
  (when-let* ((buffer (agent-shell-pod--visible-p agent-shell-pod--dashboard-name)))
    (agent-shell-pod--redraw buffer #'agent-shell-pod--render-dashboard))
  (agent-shell-pod--update-tick)
  (force-mode-line-update t))

(defun agent-shell-pod--schedule-refresh (&rest _)
  "Schedule a refresh soon, coalescing repeated requests."
  (unless agent-shell-pod--refresh-timer
    (setq agent-shell-pod--refresh-timer
          (run-at-time 0.2 nil #'agent-shell-pod--refresh))))

(defun agent-shell-pod--update-tick ()
  "Run a repeating redraw while something is busy and visible."
  (let ((needed (and (or (alist-get 'working agent-shell-pod--counts)
                         (alist-get 'initializing agent-shell-pod--counts))
                     (or (agent-shell-pod--visible-p agent-shell-pod--sidebar-name)
                         (agent-shell-pod--visible-p agent-shell-pod--dashboard-name)))))
    (cond ((and needed (not agent-shell-pod--tick-timer))
           (setq agent-shell-pod--tick-timer
                 (run-at-time agent-shell-pod-tick-interval agent-shell-pod-tick-interval
                              #'agent-shell-pod--schedule-refresh)))
          ((and (not needed) agent-shell-pod--tick-timer)
           (cancel-timer agent-shell-pod--tick-timer)
           (setq agent-shell-pod--tick-timer nil)))))

(defun agent-shell-pod--looking-at-p (buffer)
  "Return non-nil when BUFFER is in the selected window of a focused frame."
  (and (eq (frame-focus-state) t)
       (eq (agent-shell-pod--shell-of (window-buffer (selected-window))) buffer)))

(defun agent-shell-pod-notify-desktop (title body &optional _buffer)
  "Show a desktop notification with TITLE and BODY."
  (message "%s: %s" title body)
  (cond ((fboundp 'alert) (alert body :title title))
        ((and (eq system-type 'darwin) (executable-find "osascript"))
         (start-process "agent-shell-pod-notify" nil "osascript" "-e"
                        (format "display notification %S with title %S" body title)))
        ((and (featurep 'dbusbind) (require 'notifications nil t))
         (ignore-errors (notifications-notify :title title :body body :app-name "Emacs")))))

(defun agent-shell-pod--notify (buffer status body)
  "Notify about BUFFER reaching STATUS with BODY, unless you are looking."
  (when (and (memq status agent-shell-pod-notify-statuses)
             (not (agent-shell-pod--looking-at-p buffer)))
    (let ((root (agent-shell-pod--root-for (buffer-local-value 'default-directory buffer))))
      (funcall agent-shell-pod-notify-function
               (if root
                   (format "%s · %s" (agent-shell-pod--title buffer)
                           (agent-shell-pod--project-name root))
                 (agent-shell-pod--title buffer))
               body buffer))))

(defun agent-shell-pod--on-event (event)
  "Track agent-shell EVENT for the current shell buffer."
  (let ((buffer (current-buffer))
        (now (float-time))
        (data (map-elt event :data)))
    (setq agent-shell-pod--last-activity now)
    (pcase (map-elt event :event)
      ('input-submitted
       (setq agent-shell-pod--busy-since now
             agent-shell-pod--finished nil
             agent-shell-pod--error nil))
      ('permission-request
       (agent-shell-pod--notify
        buffer 'waiting
        (format "Needs permission: %s"
                (or (map-nested-elt data '(:tool-call :title)) "tool call"))))
      ('turn-complete
       (when agent-shell-pod--busy-since
         (setq agent-shell-pod--last-duration (- now agent-shell-pod--busy-since)))
       (setq agent-shell-pod--busy-since nil)
       (unless (or (agent-shell-pod--looking-at-p buffer)
                   (equal (format "%s" (map-elt data :stop-reason)) "cancelled"))
         (setq agent-shell-pod--finished t)
         (agent-shell-pod--notify
          buffer 'finished
          (format "Finished in %s"
                  (agent-shell-pod--format-duration (or agent-shell-pod--last-duration 0))))))
      ('error
       (setq agent-shell-pod--error (or (map-elt data :message) "request failed")
             agent-shell-pod--busy-since nil)
       (agent-shell-pod--notify buffer 'error agent-shell-pod--error)))
    (run-hook-with-args 'agent-shell-pod-event-functions event)
    (agent-shell-pod--schedule-refresh)))

(defun agent-shell-pod--track ()
  "Start tracking the current agent-shell buffer."
  (when (and (derived-mode-p 'agent-shell-mode)
             (not agent-shell-pod--subscription)
             agent-shell--state)
    (setq agent-shell-pod--created (or agent-shell-pod--created (float-time)))
    (condition-case err
        (setq agent-shell-pod--subscription
              (agent-shell-subscribe-to :shell-buffer (current-buffer)
                                        :on-event #'agent-shell-pod--on-event))
      (error (message "agent-shell-pod: can't track %s: %S" (buffer-name) err)))
    (add-hook 'kill-buffer-hook #'agent-shell-pod--schedule-refresh nil t)
    (agent-shell-pod--schedule-refresh)))

(defun agent-shell-pod--untrack ()
  "Stop tracking the current agent-shell buffer."
  (when agent-shell-pod--subscription
    (ignore-errors (agent-shell-unsubscribe :subscription agent-shell-pod--subscription))
    (setq agent-shell-pod--subscription nil))
  (remove-hook 'kill-buffer-hook #'agent-shell-pod--schedule-refresh t))

(defun agent-shell-pod--on-window-change (&rest _)
  "Acknowledge finished sessions you look at and redraw."
  (when-let* ((buffer (agent-shell-pod--shell-of (window-buffer (selected-window)))))
    (with-current-buffer buffer
      (when (or agent-shell-pod--finished agent-shell-pod--error)
        (setq agent-shell-pod--finished nil
              agent-shell-pod--error nil))))
  (agent-shell-pod--schedule-refresh))

(defvar agent-shell-pod--mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'agent-shell-pod-next-attention)
    (define-key map [mode-line mouse-3] #'agent-shell-pod-toggle)
    map))

(defun agent-shell-pod--mode-line ()
  "Return the global mode-line indicator string."
  (let ((parts (delq nil
                     (mapcar (lambda (status)
                               (when-let* ((n (alist-get status agent-shell-pod--counts)))
                                 (propertize (format "%s%d"
                                                     (alist-get status agent-shell-pod-status-icons)
                                                     n)
                                             'face (agent-shell-pod--status-face status))))
                             agent-shell-pod-mode-line-statuses))))
    (when parts
      (propertize (concat " " (string-join parts " ") " ")
                  'help-echo "Agents: mouse-1 next that needs you, mouse-3 sidebar"
                  'mouse-face 'mode-line-highlight
                  'local-map agent-shell-pod--mode-line-map))))

(defconst agent-shell-pod--mode-line-construct
  '(:eval (agent-shell-pod--mode-line)))

;;;###autoload
(define-minor-mode agent-shell-pod-mode
  "Track agent-shell sessions for the sidebar, dashboard and mode line."
  :global t
  :group 'agent-shell-pod
  (if agent-shell-pod-mode
      (progn
        (when agent-shell-pod-setup-keys (agent-shell-pod-setup-keys))
        (add-hook 'agent-shell-mode-hook #'agent-shell-pod--track)
        (add-hook 'window-selection-change-functions #'agent-shell-pod--on-window-change)
        (add-hook 'window-buffer-change-functions #'agent-shell-pod--on-window-change)
        (add-hook 'find-file-hook #'agent-shell-pod--schedule-refresh)
        (add-hook 'kill-buffer-hook #'agent-shell-pod--schedule-refresh)
        (unless (member agent-shell-pod--mode-line-construct global-mode-string)
          (setq global-mode-string
                (append (or global-mode-string '("")) (list agent-shell-pod--mode-line-construct))))
        (dolist (b (agent-shell-pod--sessions))
          (with-current-buffer b (agent-shell-pod--track))))
    (remove-hook 'agent-shell-mode-hook #'agent-shell-pod--track)
    (remove-hook 'window-selection-change-functions #'agent-shell-pod--on-window-change)
    (remove-hook 'window-buffer-change-functions #'agent-shell-pod--on-window-change)
    (remove-hook 'find-file-hook #'agent-shell-pod--schedule-refresh)
    (remove-hook 'kill-buffer-hook #'agent-shell-pod--schedule-refresh)
    (setq global-mode-string (delete agent-shell-pod--mode-line-construct global-mode-string))
    (dolist (b (agent-shell-pod--sessions))
      (with-current-buffer b (agent-shell-pod--untrack)))
    (when agent-shell-pod--tick-timer
      (cancel-timer agent-shell-pod--tick-timer)
      (setq agent-shell-pod--tick-timer nil)))
  (agent-shell-pod--schedule-refresh))

(defun agent-shell-pod--own-window-p (window)
  "Return non-nil if WINDOW is a side window or the sidebar window."
  (or (window-parameter window 'window-side)
      (equal (buffer-name (window-buffer window)) agent-shell-pod--sidebar-name)))

(defun agent-shell-pod--main-window (&optional no-create)
  "Return the most recently used non-side window.
Unless NO-CREATE, split the frame when there is none."
  (let ((candidates (seq-remove #'agent-shell-pod--own-window-p (window-list nil 'nomini))))
    (or (car (sort candidates (lambda (a b) (> (window-use-time a) (window-use-time b)))))
        (unless no-create
          (let ((main (window-main-window)))
            (if (agent-shell-pod--own-window-p main)
                (split-window (frame-root-window) nil 'right)
              main))))))

(defun agent-shell-pod--session-window (buffer)
  "Display session BUFFER in the place set by `agent-shell-pod-session-display'."
  (if (eq agent-shell-pod-session-display 'side-window)
      (display-buffer-in-side-window
       buffer
       `((side . ,agent-shell-pod-session-side)
         (slot . 1)
         (window-width . ,agent-shell-pod-session-width)
         (window-height . ,agent-shell-pod-session-width)
         (preserve-size . (t . nil))
         (window-parameters . ((no-delete-other-windows . t)))))
    (let ((win (agent-shell-pod--main-window)))
      (set-window-buffer win buffer)
      win)))

(defun agent-shell-pod-display-session (buffer alist)
  "Display session BUFFER where agent-shell-pod puts agents.
ALIST is the action alist.  Usable in `agent-shell-display-action'."
  (if (eq agent-shell-pod-session-display 'side-window)
      (agent-shell-pod--session-window buffer)
    (window--display-buffer buffer (agent-shell-pod--main-window) 'reuse alist)))

(defun agent-shell-pod--show (buffer &optional no-select)
  "Show session BUFFER and select its window unless NO-SELECT."
  (let ((win (or (get-buffer-window buffer)
                 (agent-shell-pod--session-window buffer))))
    (unless no-select (select-window win))
    (agent-shell-pod--schedule-refresh)
    win))

(defun agent-shell-pod--show-main (buffer)
  "Show BUFFER in the main window and select it."
  (let ((win (agent-shell-pod--main-window)))
    (set-window-buffer win buffer)
    (select-window win)
    win))

(defun agent-shell-pod--display (buffer)
  "Show session BUFFER and select it, the same way the sidebar does."
  (if (or (get-buffer-window buffer)
          (agent-shell-pod--sidebar-window)
          (eq agent-shell-pod-session-display 'side-window)
          (agent-shell-pod--own-window-p (selected-window)))
      (agent-shell-pod--show buffer)
    (switch-to-buffer buffer)
    (agent-shell-pod--schedule-refresh)))

(defun agent-shell-pod--sidebar-buffer ()
  "Return the sidebar buffer, creating it if needed."
  (or (get-buffer agent-shell-pod--sidebar-name)
      (with-current-buffer (get-buffer-create agent-shell-pod--sidebar-name)
        (agent-shell-pod-sidebar-mode)
        (current-buffer))))

(defun agent-shell-pod--sidebar-window ()
  "Return the window showing the sidebar, if any."
  (when-let* ((buffer (get-buffer agent-shell-pod--sidebar-name)))
    (get-buffer-window buffer)))

;;;###autoload
(defun agent-shell-pod ()
  "Open the agents sidebar and show the most recent agent beside it."
  (interactive)
  (unless agent-shell-pod-mode (agent-shell-pod-mode 1))
  (let* ((buffer (agent-shell-pod--sidebar-buffer))
         (win (display-buffer-in-side-window
               buffer
               `((side . ,agent-shell-pod-sidebar-side)
                 (slot . 0)
                 (window-width . ,agent-shell-pod-sidebar-width)
                 (preserve-size . (t . nil))
                 (dedicated . t)
                 (window-parameters . ((no-delete-other-windows . t)))))))
    (let ((recent (car (agent-shell-pod--sessions))))
      (when (and recent (not (agent-shell-pod--visible-session)))
        (agent-shell-pod--session-window recent)))
    (agent-shell-pod--redraw buffer #'agent-shell-pod--render-sidebar)
    (agent-shell-pod--update-counts)
    (agent-shell-pod--update-tick)
    (select-window win)))

;;;###autoload
(defun agent-shell-pod-toggle ()
  "Toggle the agents sidebar."
  (interactive)
  (if-let* ((win (agent-shell-pod--sidebar-window)))
      (delete-window win)
    (agent-shell-pod)))

;;;###autoload
(defun agent-shell-pod-dashboard ()
  "Show the agents dashboard in the main window."
  (interactive)
  (unless agent-shell-pod-mode (agent-shell-pod-mode 1))
  (let ((buffer (or (get-buffer agent-shell-pod--dashboard-name)
                    (with-current-buffer (get-buffer-create agent-shell-pod--dashboard-name)
                      (agent-shell-pod-dashboard-mode)
                      (current-buffer)))))
    (if (agent-shell-pod--own-window-p (selected-window))
        (agent-shell-pod--show-main buffer)
      (switch-to-buffer buffer))
    (agent-shell-pod--redraw buffer #'agent-shell-pod--render-dashboard)
    (agent-shell-pod--update-tick)))

(defun agent-shell-pod-refresh ()
  "Clear cached project data and redraw."
  (interactive)
  (clrhash agent-shell-pod--cache)
  (agent-shell-pod--refresh))

(defun agent-shell-pod--item-or-error (&rest types)
  "Return the item at point, requiring one of TYPES."
  (let ((item (agent-shell-pod--item-at)))
    (unless (and item (memq (plist-get item :type) types))
      (user-error "No %s here" (mapconcat #'symbol-name types " or ")))
    item))

(defun agent-shell-pod--session-at-point ()
  "Return the session at point, or the current agent-shell buffer."
  (or (let ((item (agent-shell-pod--item-at)))
        (and (eq (plist-get item :type) 'session) (plist-get item :buffer)))
      (agent-shell-pod--shell-of (current-buffer))
      (user-error "No agent session here")))

(defun agent-shell-pod-toggle-fold ()
  "Fold or unfold the project or worktree at point."
  (interactive)
  (let ((item (agent-shell-pod--item-at)))
    (when (eq (plist-get item :type) 'session)
      (setq item (if (plist-get item :branch)
                     (list :type 'worktree :toplevel (plist-get item :toplevel))
                   (list :type 'project :root (plist-get item :root)
                         :sessions (list item)))))
    (when-let* ((key (agent-shell-pod--fold-key item)))
      (puthash key (not (agent-shell-pod--folded-p item)) agent-shell-pod--folded)
      (agent-shell-pod--refresh))))

(defun agent-shell-pod-visit ()
  "Open the session at point, fold a heading, or start a new agent."
  (interactive)
  (let ((item (agent-shell-pod--item-at)))
    (pcase (plist-get item :type)
      ('session
       (if (derived-mode-p 'agent-shell-pod-dashboard-mode)
           (switch-to-buffer (plist-get item :buffer))
         (agent-shell-pod--show (plist-get item :buffer))))
      ('new (agent-shell-pod-new-session))
      ('worktree
       (if (plist-get item :sessions)
           (agent-shell-pod-toggle-fold)
         (agent-shell-pod-new-session)))
      ('project (agent-shell-pod-toggle-fold)))))

(defun agent-shell-pod-mouse-visit (event)
  "Visit the item clicked with EVENT."
  (interactive "e")
  (mouse-set-point event)
  (agent-shell-pod-visit))

(defun agent-shell-pod-peek ()
  "Show the session at point in the main window without selecting it."
  (interactive)
  (agent-shell-pod--show (agent-shell-pod--session-at-point) t))

(defun agent-shell-pod-visit-other-window ()
  "Show the session at point in another window and select it."
  (interactive)
  (let ((buffer (agent-shell-pod--session-at-point)))
    (if (derived-mode-p 'agent-shell-pod-dashboard-mode)
        (pop-to-buffer buffer t)
      (agent-shell-pod--show buffer))))

(defun agent-shell-pod-next-item (&optional n)
  "Move to the next N item lines."
  (interactive "p")
  (dotimes (_ (abs (or n 1)))
    (let ((start (agent-shell-pod--item-key (agent-shell-pod--item-at))))
      (forward-line (if (< (or n 1) 0) -1 1))
      (while (and (not (bobp)) (not (eobp))
                  (or (not (agent-shell-pod--item-at))
                      (equal (agent-shell-pod--item-key (agent-shell-pod--item-at)) start)))
        (forward-line (if (< (or n 1) 0) -1 1)))
      (when (and (< (or n 1) 0) (agent-shell-pod--item-at))
        (let ((key (agent-shell-pod--item-key (agent-shell-pod--item-at))))
          (while (and (not (bobp))
                      (equal (agent-shell-pod--item-key
                              (agent-shell-pod--item-at (line-beginning-position 0)))
                             key))
            (forward-line -1)))))))

(defun agent-shell-pod-previous-item (&optional n)
  "Move to the previous N item lines."
  (interactive "p")
  (agent-shell-pod-next-item (- (or n 1))))

(defun agent-shell-pod-read-project-dir ()
  "Prompt for a project directory, using Projectile's list when it is on."
  (if (and (bound-and-true-p projectile-mode)
           (bound-and-true-p projectile-known-projects))
      (completing-read "Project: " projectile-known-projects nil t)
    (project-prompt-project-dir)))

(defun agent-shell-pod--read-root ()
  "Prompt for a project and return its root."
  (let ((dir (funcall agent-shell-pod-read-project-function)))
    (or (agent-shell-pod--root-for dir) (agent-shell-pod--dir dir))))

(defun agent-shell-pod--random-name ()
  "Return a random worktree name."
  (if (fboundp 'agent-shell-worktree--generate-name)
      (agent-shell-worktree--generate-name)
    (format-time-string "%m%d-%H%M%S")))

(defun agent-shell-pod-create-worktree (root)
  "Create a git worktree for the project at ROOT and return its directory."
  (interactive (list (agent-shell-pod--read-root)))
  (unless (agent-shell-pod--git-info root)
    (user-error "%s is not a git repository" (abbreviate-file-name root)))
  (let* ((branch (read-string "New branch: "
                              (concat agent-shell-pod-branch-prefix
                                      (agent-shell-pod--random-name))))
         (slug (replace-regexp-in-string "[^[:alnum:]._-]+" "-" branch))
         (default-path (funcall agent-shell-pod-worktree-directory-function root slug))
         (path (agent-shell-pod--dir
                (read-directory-name "Worktree directory: "
                                     (file-name-directory (directory-file-name default-path))
                                     default-path nil
                                     (file-name-nondirectory default-path))))
         (exists (agent-shell-pod--git root "rev-parse" "--verify" "--quiet"
                                       (concat "refs/heads/" branch)))
         (base (unless exists
                 (completing-read
                  "Base: "
                  (split-string (or (agent-shell-pod--git
                                     root "for-each-ref" "--format=%(refname:short)"
                                     "refs/heads" "refs/remotes")
                                    "")
                                "\n" t)
                  nil nil nil nil
                  (or (plist-get (agent-shell-pod--git-info root) :branch) "HEAD")))))
    (when (file-exists-p path)
      (user-error "%s already exists" (abbreviate-file-name path)))
    (make-directory (file-name-directory (directory-file-name path)) t)
    (message "Creating worktree %s…" branch)
    (if exists
        (agent-shell-pod--git-or-error root "worktree" "add" (directory-file-name path) branch)
      (agent-shell-pod--git-or-error root "worktree" "add" "-b" branch
                                     (directory-file-name path) base))
    (clrhash agent-shell-pod--cache)
    (message "Created worktree %s" (abbreviate-file-name path))
    path))

(defun agent-shell-pod--read-existing-worktree (root)
  "Prompt for an existing worktree of ROOT and return its directory."
  (let* ((choices (mapcar (lambda (wt)
                            (cons (format "%-30s %s"
                                          (plist-get wt :branch)
                                          (abbreviate-file-name (plist-get wt :toplevel)))
                                  (plist-get wt :toplevel)))
                          (agent-shell-pod--worktrees root))))
    (unless choices (user-error "No worktrees found"))
    (cdr (assoc (completing-read "Worktree: " choices nil t) choices))))

(defun agent-shell-pod--choose-dir (root checkout &optional force-worktree)
  "Decide where to start an agent for ROOT.
CHECKOUT is the default directory.  FORCE-WORKTREE creates a worktree."
  (cond
   ((not (agent-shell-pod--git-info root)) checkout)
   (force-worktree (agent-shell-pod-create-worktree root))
   (t
    (pcase agent-shell-pod-worktree-policy
      ('never checkout)
      ('always (agent-shell-pod-create-worktree root))
      (_
       (pcase (car (read-multiple-choice
                    (format "Start agent in %s" (agent-shell-pod--project-name root))
                    `((?c "current checkout"
                          ,(format "Run in %s" (abbreviate-file-name checkout)))
                      (?n "new worktree" "Create a branch and worktree for this agent")
                      (?e "existing worktree" "Pick one of the project's worktrees"))))
         (?c checkout)
         (?n (agent-shell-pod-create-worktree root))
         (?e (agent-shell-pod--read-existing-worktree root))))))))

(defun agent-shell-pod--start-in (dir)
  "Start an agent shell in DIR and show it in the main window."
  (let* ((default-directory (agent-shell-pod--dir dir))
         (config (or (and (fboundp 'agent-shell--auto-preferred-config)
                          (agent-shell--auto-preferred-config))
                     (agent-shell-select-config :prompt "Start agent: ")
                     (user-error "No agent configured")))
         (agent-shell-display-action (if (or (agent-shell-pod--sidebar-window)
                                             (eq agent-shell-pod-session-display 'side-window))
                                         '((agent-shell-pod-display-session))
                                       agent-shell-display-action)))
    (prog1 (agent-shell-start :config config)
      (clrhash agent-shell-pod--cache)
      (agent-shell-pod--schedule-refresh))))

(defun agent-shell-pod--context ()
  "Return (ROOT . CHECKOUT) for the item at point or the current buffer."
  (let ((item (agent-shell-pod--item-at)))
    (if item
        (let ((root (plist-get item :root)))
          (cons root
                (or (and (memq (plist-get item :type) '(worktree session))
                         (plist-get item :toplevel))
                    root)))
      (let* ((root (or (agent-shell-pod--root-for default-directory)
                       (agent-shell-pod--read-root)))
             (git (agent-shell-pod--git-info default-directory)))
        (cons root (if (equal (plist-get git :main) root)
                       (plist-get git :toplevel)
                     root))))))

;;;###autoload
(defun agent-shell-pod-new-session (&optional arg)
  "Start a new agent in the project at point or the current project.
On a worktree or session line, start in that worktree.  On a project
line, follow `agent-shell-pod-worktree-policy'.  With prefix ARG,
prompt for the project."
  (interactive "P")
  (unless agent-shell-pod-mode (agent-shell-pod-mode 1))
  (let* ((item (agent-shell-pod--item-at))
         (context (if arg
                      (let ((root (agent-shell-pod--read-root))) (cons root root))
                    (agent-shell-pod--context)))
         (dir (if (and (not arg) (memq (plist-get item :type) '(worktree session)))
                  (cdr context)
                (agent-shell-pod--choose-dir (car context) (cdr context)))))
    (agent-shell-pod--start-in dir)))

;;;###autoload
(defun agent-shell-pod-new-worktree-session (&optional arg)
  "Create a new git worktree and start an agent in it.
With prefix ARG, prompt for the project."
  (interactive "P")
  (unless agent-shell-pod-mode (agent-shell-pod-mode 1))
  (let ((root (if arg (agent-shell-pod--read-root) (car (agent-shell-pod--context)))))
    (agent-shell-pod--start-in (agent-shell-pod--choose-dir root root t))))

(defun agent-shell-pod--attention-queue ()
  "Return sessions that need you, most urgent first."
  (let ((rank '((waiting . 0) (error . 1) (finished . 2))))
    (mapcar #'car
            (sort (delq nil
                        (mapcar (lambda (b)
                                  (let ((status (agent-shell-pod--status b)))
                                    (when (agent-shell-pod--attention-p status)
                                      (list b (alist-get status rank)
                                            (or (buffer-local-value 'agent-shell-pod--last-activity b)
                                                0)))))
                                (agent-shell-pod--sessions)))
                  (lambda (a b)
                    (if (= (nth 1 a) (nth 1 b))
                        (< (nth 2 a) (nth 2 b))
                      (< (nth 1 a) (nth 1 b))))))))

;;;###autoload
(defun agent-shell-pod-next-attention ()
  "Jump to the next agent that needs you."
  (interactive)
  (let* ((queue (agent-shell-pod--attention-queue))
         (current (agent-shell-pod--shell-of (window-buffer (selected-window))))
         (next (or (cadr (memq current queue)) (car queue))))
    (unless next (user-error "No agent needs you"))
    (agent-shell-pod--display next)
    (when (eq (agent-shell-pod--status next) 'waiting)
      (with-current-buffer next
        (ignore-errors (agent-shell-jump-to-latest-permission-button-row))))))

(defun agent-shell-pod--read-session (prompt sessions)
  "Read one of SESSIONS with PROMPT, or return it when there is only one."
  (let ((choices (mapcar (lambda (b)
                           (cons (format "%s %s  %s  %s"
                                         (agent-shell-pod--icon (agent-shell-pod--status b))
                                         (agent-shell-pod--title b)
                                         (propertize (agent-shell-pod--project-name
                                                      (or (agent-shell-pod--root-for
                                                           (buffer-local-value 'default-directory b))
                                                          (buffer-local-value 'default-directory b)))
                                                     'face 'agent-shell-pod-branch)
                                         (propertize (buffer-name b) 'face 'agent-shell-pod-meta))
                                 b))
                         sessions)))
    (cond ((null choices) (user-error "No agent sessions"))
          ((null (cdr choices)) (cdar choices))
          (t (cdr (assoc (completing-read prompt choices nil t) choices))))))

;;;###autoload
(defun agent-shell-pod-switch ()
  "Switch to an agent session with completion."
  (interactive)
  (agent-shell-pod--display
   (agent-shell-pod--read-session "Agent: " (agent-shell-pod--sessions))))

(defun agent-shell-pod-kill ()
  "Kill the session at point."
  (interactive)
  (let ((buffer (agent-shell-pod--session-at-point)))
    (when (yes-or-no-p (format "Kill %s? " (agent-shell-pod--title buffer)))
      (kill-buffer buffer)
      (agent-shell-pod--schedule-refresh))))

(defun agent-shell-pod-rename (label)
  "Set the sidebar LABEL of the session at point."
  (interactive
   (list (read-string "Label: " (agent-shell-pod--title (agent-shell-pod--session-at-point)))))
  (with-current-buffer (agent-shell-pod--session-at-point)
    (setq agent-shell-pod--label (unless (string-empty-p label) label)))
  (agent-shell-pod--refresh))

(defun agent-shell-pod-restart ()
  "Restart the session at point."
  (interactive)
  (with-current-buffer (agent-shell-pod--session-at-point)
    (call-interactively #'agent-shell-restart)))

(defun agent-shell-pod-interrupt ()
  "Interrupt the session at point."
  (interactive)
  (with-current-buffer (agent-shell-pod--session-at-point)
    (agent-shell-interrupt)))

(defun agent-shell-pod-set-mode ()
  "Set the session mode of the session at point."
  (interactive)
  (with-current-buffer (agent-shell-pod--session-at-point)
    (call-interactively #'agent-shell-set-session-mode)))

(defun agent-shell-pod-set-model ()
  "Set the model of the session at point."
  (interactive)
  (with-current-buffer (agent-shell-pod--session-at-point)
    (call-interactively #'agent-shell-set-session-model)))

(defun agent-shell-pod--dir-at-point ()
  "Return the most specific directory for the item at point."
  (let ((item (agent-shell-pod--item-or-error 'project 'worktree 'session 'new)))
    (or (plist-get item :toplevel) (plist-get item :root))))

(defun agent-shell-pod--in-main-window (dir command)
  "Call COMMAND interactively in DIR from the main window."
  (select-window (agent-shell-pod--main-window))
  (let ((default-directory (agent-shell-pod--dir dir)))
    (call-interactively command)))

(defun agent-shell-pod-find-file ()
  "Find a file in the project or worktree at point."
  (interactive)
  (agent-shell-pod--in-main-window (agent-shell-pod--dir-at-point) #'project-find-file))

(defun agent-shell-pod-dired ()
  "Open Dired on the project or worktree at point."
  (interactive)
  (let ((dir (agent-shell-pod--dir-at-point)))
    (select-window (agent-shell-pod--main-window))
    (dired dir)))

(defun agent-shell-pod-vc ()
  "Open version control status for the project or worktree at point."
  (interactive)
  (let ((dir (agent-shell-pod--dir-at-point)))
    (select-window (agent-shell-pod--main-window))
    (if (fboundp 'magit-status-setup-buffer)
        (magit-status-setup-buffer dir)
      (vc-dir dir))))

(defun agent-shell-pod-switch-project ()
  "Run `project-switch-project' on the project at point."
  (interactive)
  (let ((dir (agent-shell-pod--dir-at-point)))
    (select-window (agent-shell-pod--main-window))
    (project-switch-project dir)))

(defun agent-shell-pod-add-project (root)
  "Add the project at ROOT to the list."
  (interactive (list (agent-shell-pod--read-root)))
  (setq agent-shell-pod--hidden-roots (delete root agent-shell-pod--hidden-roots))
  (cl-pushnew root agent-shell-pod--extra-roots :test #'equal)
  (puthash (list 'project root) nil agent-shell-pod--folded)
  (agent-shell-pod--refresh))

(defun agent-shell-pod-hide-project ()
  "Hide the project at point until it has a session or is added again."
  (interactive)
  (let ((item (agent-shell-pod--item-or-error 'project)))
    (when (plist-get item :sessions)
      (user-error "Project has running agents"))
    (setq agent-shell-pod--extra-roots (delete (plist-get item :root) agent-shell-pod--extra-roots))
    (cl-pushnew (plist-get item :root) agent-shell-pod--hidden-roots :test #'equal)
    (agent-shell-pod--refresh)))

(defun agent-shell-pod-remove-worktree (&optional force)
  "Remove the git worktree at point.
With FORCE, remove it even when it has uncommitted work."
  (interactive "P")
  (let ((item (agent-shell-pod--item-or-error 'worktree)))
    (when (plist-get item :primary)
      (user-error "Won't remove the primary checkout"))
    (when (plist-get item :sessions)
      (user-error "Kill the agents in this worktree first"))
    (when (yes-or-no-p (format "Remove worktree %s? "
                               (abbreviate-file-name (plist-get item :toplevel))))
      (apply #'agent-shell-pod--git-or-error (plist-get item :root)
             (append '("worktree" "remove")
                     (when force '("--force"))
                     (list (directory-file-name (plist-get item :toplevel)))))
      (clrhash agent-shell-pod--cache)
      (agent-shell-pod--refresh))))

(define-minor-mode agent-shell-pod-follow-mode
  "Preview the session at point in the main window as you move."
  :lighter " Follow"
  (if agent-shell-pod-follow-mode
      (add-hook 'post-command-hook #'agent-shell-pod--follow nil t)
    (remove-hook 'post-command-hook #'agent-shell-pod--follow t)))

(defun agent-shell-pod--follow ()
  "Preview the session at point if it changed."
  (let ((item (agent-shell-pod--item-at)))
    (when (and (eq (plist-get item :type) 'session)
               (not (eq (plist-get item :buffer) agent-shell-pod--follow-last)))
      (setq agent-shell-pod--follow-last (plist-get item :buffer))
      (agent-shell-pod--show (plist-get item :buffer) t))))

(defun agent-shell-pod-quit ()
  "Close the sidebar, or quit the dashboard window."
  (interactive)
  (if (derived-mode-p 'agent-shell-pod-sidebar-mode)
      (agent-shell-pod-toggle)
    (quit-window)))

(defconst agent-shell-pod--keys
  '(("RET" . agent-shell-pod-visit)
    ("TAB" . agent-shell-pod-toggle-fold)
    ("o" . agent-shell-pod-peek)
    ("O" . agent-shell-pod-visit-other-window)
    ("j" . agent-shell-pod-next-item)
    ("k" . agent-shell-pod-previous-item)
    ("c" . agent-shell-pod-new-session)
    ("w" . agent-shell-pod-new-worktree-session)
    ("W" . agent-shell-pod-remove-worktree)
    ("J" . agent-shell-pod-next-attention)
    ("x" . agent-shell-pod-kill)
    ("r" . agent-shell-pod-rename)
    ("R" . agent-shell-pod-restart)
    ("i" . agent-shell-pod-interrupt)
    ("m" . agent-shell-pod-set-mode)
    ("M" . agent-shell-pod-set-model)
    ("f" . agent-shell-pod-find-file)
    ("d" . agent-shell-pod-dired)
    ("v" . agent-shell-pod-vc)
    ("P" . agent-shell-pod-switch-project)
    ("+" . agent-shell-pod-add-project)
    ("-" . agent-shell-pod-hide-project)
    ("F" . agent-shell-pod-follow-mode)
    ("D" . agent-shell-pod-dashboard)
    ("S" . agent-shell-pod)
    ("q" . agent-shell-pod-quit)
    ("?" . agent-shell-pod-sidebar-menu))
  "Keys for the sidebar and dashboard, in Emacs and in evil normal state.")

(defconst agent-shell-pod--emacs-only-keys
  '(("n" . agent-shell-pod-next-item)
    ("p" . agent-shell-pod-previous-item)
    ("SPC" . agent-shell-pod-peek)
    ("g" . agent-shell-pod-refresh)
    ("C-c C-c" . agent-shell-pod-interrupt)
    ("<mouse-1>" . agent-shell-pod-mouse-visit))
  "Extra keys for the sidebar and dashboard outside evil.")

(defconst agent-shell-pod--evil-only-keys
  '(("<return>" . agent-shell-pod-visit)
    ("<tab>" . agent-shell-pod-toggle-fold)
    ("gr" . agent-shell-pod-refresh))
  "Extra evil normal-state keys for the sidebar and dashboard.")

(defvar agent-shell-pod-base-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (pcase-dolist (`(,key . ,command) (append agent-shell-pod--keys
                                             agent-shell-pod--emacs-only-keys))
      (keymap-set map key command))
    map)
  "Keys shared by the sidebar and the dashboard.")

(defvar-keymap agent-shell-pod-sidebar-mode-map
  :parent agent-shell-pod-base-map)

(defvar-keymap agent-shell-pod-dashboard-mode-map
  :parent agent-shell-pod-base-map)

(defun agent-shell-pod--sidebar-header ()
  "Return the sidebar header line."
  (let* ((waiting (+ (alist-get 'waiting agent-shell-pod--counts 0)
                     (alist-get 'error agent-shell-pod--counts 0)))
         (finished (alist-get 'finished agent-shell-pod--counts 0))
         (working (alist-get 'working agent-shell-pod--counts 0))
         (right (string-join
                 (delq nil
                       (list (when (> waiting 0)
                               (propertize (format "%s %d" (alist-get 'waiting agent-shell-pod-status-icons) waiting)
                                           'face 'agent-shell-pod-waiting))
                             (when (> finished 0)
                               (propertize (format "%s %d" (alist-get 'finished agent-shell-pod-status-icons) finished)
                                           'face 'agent-shell-pod-finished))
                             (when (> working 0)
                               (propertize (format "%s %d" (alist-get 'working agent-shell-pod-status-icons) working)
                                           'face 'agent-shell-pod-working))))
                 "  ")))
    (concat (propertize " Agents" 'face 'agent-shell-pod-project)
            (propertize " " 'display `(space :align-to (- right ,(1+ (string-width right)))))
            right)))

(define-derived-mode agent-shell-pod-sidebar-mode special-mode "Agents"
  "Sidebar listing agent sessions by project and worktree.

\\{agent-shell-pod-sidebar-mode-map}"
  (setq-local truncate-lines t
              cursor-type nil
              buffer-read-only t
              header-line-format '(:eval (agent-shell-pod--sidebar-header)))
  (when agent-shell-pod-hide-sidebar-mode-line
    (setq-local mode-line-format nil))
  (hl-line-mode 1))

(define-derived-mode agent-shell-pod-dashboard-mode special-mode "Agents Dashboard"
  "Dashboard of all agent sessions grouped by project.

\\{agent-shell-pod-dashboard-mode-map}"
  (setq-local truncate-lines t
              buffer-read-only t
              header-line-format
              (substitute-command-keys
               (concat " \\<agent-shell-pod-dashboard-mode-map>"
                       "\\[agent-shell-pod-visit] open  "
                       "\\[agent-shell-pod-new-session] new  "
                       "\\[agent-shell-pod-new-worktree-session] new worktree  "
                       "\\[agent-shell-pod-next-attention] next needing you  "
                       "\\[agent-shell-pod-toggle-fold] fold  "
                       "\\[agent-shell-pod-refresh] refresh  "
                       "\\[agent-shell-pod-sidebar-menu] all keys")))
  (hl-line-mode 1))

(defvar-keymap agent-shell-pod-command-map
  :doc "Global commands for agent-shell-pod.  Bind it to a prefix key."
  "s" #'agent-shell-pod-toggle
  "d" #'agent-shell-pod-dashboard
  "n" #'agent-shell-pod-new-session
  "w" #'agent-shell-pod-new-worktree-session
  "j" #'agent-shell-pod-next-attention
  "b" #'agent-shell-pod-switch
  "l" #'agent-shell-pod-menu
  "o" #'agent-shell-pod-toggle-focus)

(defun agent-shell-pod--pod-buffer-p (buffer)
  "Return non-nil when BUFFER is the sidebar or the dashboard."
  (member (buffer-name buffer)
          (list agent-shell-pod--sidebar-name agent-shell-pod--dashboard-name)))

(defun agent-shell-pod--menu-dir ()
  "Return the directory that menu commands act on."
  (let ((item (agent-shell-pod--item-at)))
    (or (plist-get item :toplevel)
        (plist-get item :root)
        (when-let* ((shell (agent-shell-pod--shell-of (current-buffer))))
          (buffer-local-value 'default-directory shell))
        default-directory)))

(defun agent-shell-pod--project-sessions (&optional dir)
  "Return sessions in the project of DIR, most recently used first.
Sessions in the same checkout as DIR come first."
  (let* ((dir (agent-shell-pod--dir (or dir (agent-shell-pod--menu-dir))))
         (root (or (agent-shell-pod--root-for dir) dir))
         (top (plist-get (agent-shell-pod--git-info dir) :toplevel))
         (mine (seq-filter
                (lambda (b)
                  (let ((d (agent-shell-pod--dir (buffer-local-value 'default-directory b))))
                    (equal (or (agent-shell-pod--root-for d) d) root)))
                (agent-shell-pod--sessions)))
         (here (seq-filter
                (lambda (b)
                  (and top (equal (plist-get (agent-shell-pod--git-info
                                              (buffer-local-value 'default-directory b))
                                             :toplevel)
                                  top)))
                mine)))
    (append here (seq-difference mine here))))

(defun agent-shell-pod--work-window ()
  "Return the most recently used other window showing ordinary work."
  (seq-find (lambda (w)
              (let ((b (window-buffer w)))
                (not (or (eq w (selected-window))
                         (window-parameter w 'window-side)
                         (agent-shell-pod--shell-of b)
                         (agent-shell-pod--pod-buffer-p b)))))
            (agent-shell-pod--windows-by-use)))

(defun agent-shell-pod--previous-work-buffer (window)
  "Return the last ordinary buffer shown in WINDOW."
  (seq-find (lambda (b)
              (and (buffer-live-p b)
                   (not (minibufferp b))
                   (not (agent-shell-pod--shell-of b))
                   (not (agent-shell-pod--pod-buffer-p b))))
            (mapcar #'car (window-prev-buffers window))))

;;;###autoload
(defun agent-shell-pod-open-project-session ()
  "Show and select the most recent agent of the current project."
  (interactive)
  (agent-shell-pod--display
   (or (car (agent-shell-pod--project-sessions))
       (user-error "No agent in this project"))))

;;;###autoload
(defun agent-shell-pod-toggle-focus ()
  "Jump between the project's agent and the buffer you were working in."
  (interactive)
  (if (agent-shell-pod--shell-of (current-buffer))
      (if-let* ((win (agent-shell-pod--work-window)))
          (select-window win)
        (switch-to-buffer
         (or (agent-shell-pod--previous-work-buffer (selected-window))
             (user-error "No buffer to go back to"))))
    (agent-shell-pod-open-project-session)))

;;;###autoload
(defun agent-shell-pod-toggle-agent-window ()
  "Hide the visible agent, or show the project's agent when none is visible."
  (interactive)
  (if-let* ((win (seq-find (lambda (w) (agent-shell-pod--shell-of (window-buffer w)))
                           (agent-shell-pod--windows-by-use))))
      (if (window-parameter win 'window-side)
          (delete-window win)
        (set-window-buffer win (or (agent-shell-pod--previous-work-buffer win)
                                   (other-buffer (window-buffer win) t)))
        (agent-shell-pod--schedule-refresh))
    (agent-shell-pod-open-project-session)))

;;;###autoload
(defun agent-shell-pod-close-session ()
  "Close the current agent, the one at point, or one from this project."
  (interactive)
  (let ((buffer (or (let ((item (agent-shell-pod--item-at)))
                      (and (eq (plist-get item :type) 'session) (plist-get item :buffer)))
                    (agent-shell-pod--shell-of (current-buffer))
                    (agent-shell-pod--read-session
                     "Close agent: "
                     (or (agent-shell-pod--project-sessions)
                         (user-error "No agent in this project"))))))
    (when (y-or-n-p (format "Close %s? " (agent-shell-pod--title buffer)))
      (kill-buffer buffer)
      (agent-shell-pod--schedule-refresh))))

(defun agent-shell-pod--menu-has-session-p ()
  "Return non-nil when the menu has an agent to act on."
  (or (agent-shell-pod--shell-of (current-buffer))
      (agent-shell-pod--project-sessions)))

(defun agent-shell-pod--menu-git-p ()
  "Return non-nil for a git project in the menu's context."
  (agent-shell-pod--git-info (agent-shell-pod--dir (agent-shell-pod--menu-dir))))

(defun agent-shell-pod--menu-any-session-p ()
  "Return non-nil when any agent is running."
  (agent-shell-pod--sessions))

(defun agent-shell-pod--menu-attention-p ()
  "Return non-nil when an agent needs you."
  (agent-shell-pod--attention-queue))

(defun agent-shell-pod--menu-description ()
  "Return the heading of `agent-shell-pod-menu'."
  (let* ((dir (agent-shell-pod--dir (agent-shell-pod--menu-dir)))
         (root (agent-shell-pod--root-for dir))
         (branch (plist-get (agent-shell-pod--git-info dir) :branch))
         (sessions (agent-shell-pod--project-sessions dir)))
    (concat (propertize "Agents" 'face 'transient-heading)
            "  "
            (if root
                (propertize (agent-shell-pod--project-name root) 'face 'agent-shell-pod-project)
              (propertize "no project" 'face 'agent-shell-pod-meta))
            (if branch (concat " " (propertize branch 'face 'agent-shell-pod-branch)) "")
            (if sessions
                (concat "  " (mapconcat (lambda (b) (agent-shell-pod--icon (agent-shell-pod--status b)))
                                        sessions " "))
              ""))))

(defun agent-shell-pod--session-menu-description ()
  "Return the heading of `agent-shell-pod-session-menu'."
  (if-let* ((buffer (agent-shell-pod--shell-of (current-buffer))))
      (let ((info (agent-shell-pod--session-info buffer)))
        (concat (agent-shell-pod--icon (plist-get info :status))
                " "
                (propertize (plist-get info :title) 'face 'transient-heading)
                (propertize
                 (concat "  "
                         (string-join
                          (delq nil (list (agent-shell-pod--project-name (plist-get info :root))
                                          (plist-get info :branch)
                                          (plist-get info :model)
                                          (agent-shell-pod--status-text info)))
                          " · "))
                 'face 'agent-shell-pod-meta)))
    (propertize "Agent" 'face 'transient-heading)))

;;;###autoload (autoload 'agent-shell-pod-menu "agent-shell-pod" nil t)
(transient-define-prefix agent-shell-pod-menu ()
  "Agents for the current project."
  [:description agent-shell-pod--menu-description
   ["This project"
    ("s" "Start agent" agent-shell-pod-new-session)
    ("W" "Start agent in new worktree" agent-shell-pod-new-worktree-session
     :inapt-if-not agent-shell-pod--menu-git-p)
    ("o" "Open agent" agent-shell-pod-open-project-session
     :inapt-if-not agent-shell-pod--menu-has-session-p)
    ("b" "Toggle between agent and buffer" agent-shell-pod-toggle-focus
     :inapt-if-not agent-shell-pod--menu-has-session-p)
    ("t" "Show or hide agent" agent-shell-pod-toggle-agent-window
     :inapt-if-not agent-shell-pod--menu-has-session-p)
    ("q" "Close agent" agent-shell-pod-close-session
     :inapt-if-not agent-shell-pod--menu-has-session-p)]
   ["All agents"
    ("w" "Toggle sidebar" agent-shell-pod-toggle)
    ("d" "Dashboard" agent-shell-pod-dashboard)
    ("j" "Next needing you" agent-shell-pod-next-attention
     :inapt-if-not agent-shell-pod--menu-attention-p)
    ("a" "Switch agent" agent-shell-pod-switch
     :inapt-if-not agent-shell-pod--menu-any-session-p)]])

;;;###autoload (autoload 'agent-shell-pod-session-menu "agent-shell-pod" nil t)
(transient-define-prefix agent-shell-pod-session-menu ()
  "Commands for the current agent session."
  [:description agent-shell-pod--session-menu-description
   ["Navigation"
    ("<tab>" "Next item" agent-shell-next-item :transient t)
    ("<backtab>" "Previous item" agent-shell-previous-item :transient t)]
   ["Insert"
    ("e" "Shell command" agent-shell-insert-shell-command-output)
    ("f" "File" agent-shell-insert-file :transient t)
    ("s" "Screenshot" agent-shell-send-screenshot :transient t)
    ("i" "Clipboard image" agent-shell-send-clipboard-image :transient t)
    ("d" "Dwim" agent-shell-send-dwim :transient t)]
   ["Prompt"
    ("p" "Compose prompt" agent-shell-prompt-compose)]]
  [["Session"
    ("m" "Cycle modes" agent-shell-cycle-session-mode :transient t)
    ("M" "Set mode" agent-shell-set-session-mode :transient t)
    ("v" "Set model" agent-shell-set-session-model :transient t)
    ("t" "Set thought level" agent-shell-set-session-thought-level :transient t)
    ("o" "Set option" agent-shell-set-session-config-option :transient t)
    ("c" "Clear" shell-maker-clear-buffer :transient t)
    ("C" "Interrupt" agent-shell-interrupt :transient t)
    ("y" "Copy session id" agent-shell-copy-session-id)]
   ["Agents"
    ("b" "Back to buffer" agent-shell-pod-toggle-focus)
    ("w" "Toggle sidebar" agent-shell-pod-toggle)
    ("D" "Dashboard" agent-shell-pod-dashboard)
    ("N" "New agent" agent-shell-pod-new-session)
    ("W" "New agent in worktree" agent-shell-pod-new-worktree-session)
    ("S" "Switch agent" agent-shell-pod-switch)
    ("j" "Next needing you" agent-shell-pod-next-attention
     :inapt-if-not agent-shell-pod--menu-attention-p)]
   ["This agent"
    ("L" "Label" agent-shell-pod-rename)
    ("F" "Fork" agent-shell-fork)
    ("r" "Restart" agent-shell-reload)
    ("q" "Close" agent-shell-pod-close-session)]
   ["Misc"
    ("T" "Open transcript" agent-shell-open-transcript)
    ("l" "View ACP logs" agent-shell-view-acp-logs)
    ("x" "View traffic" agent-shell-view-traffic)]]
  (interactive)
  (unless (agent-shell-pod--shell-of (current-buffer))
    (user-error "Not in an agent-shell buffer"))
  (transient-setup 'agent-shell-pod-session-menu))

(defun agent-shell-pod--point-type ()
  "Return the type of the item at point."
  (plist-get (agent-shell-pod--item-at) :type))

(defun agent-shell-pod--point-session-p ()
  "Return non-nil when point is on an agent."
  (eq (agent-shell-pod--point-type) 'session))

(defun agent-shell-pod--point-item-p ()
  "Return non-nil when point is on any item."
  (agent-shell-pod--item-at))

(defun agent-shell-pod--point-foldable-p ()
  "Return non-nil when point is on something that folds."
  (memq (agent-shell-pod--point-type) '(project worktree session)))

(defun agent-shell-pod--point-git-p ()
  "Return non-nil when point is in a git project."
  (and (agent-shell-pod--item-at) (agent-shell-pod--menu-git-p)))

(defun agent-shell-pod--point-removable-worktree-p ()
  "Return non-nil when point is on a worktree that can be removed."
  (let ((item (agent-shell-pod--item-at)))
    (and (eq (plist-get item :type) 'worktree)
         (not (plist-get item :primary))
         (null (plist-get item :sessions)))))

(defun agent-shell-pod--point-hideable-project-p ()
  "Return non-nil when point is on a project without agents."
  (let ((item (agent-shell-pod--item-at)))
    (and (eq (plist-get item :type) 'project)
         (null (plist-get item :sessions)))))

(defun agent-shell-pod--sidebar-menu-description ()
  "Return the heading of `agent-shell-pod-sidebar-menu'."
  (let* ((item (agent-shell-pod--item-at))
         (root (plist-get item :root))
         (project (and root (propertize (agent-shell-pod--project-name root)
                                        'face 'agent-shell-pod-project))))
    (concat
     (propertize "Agents" 'face 'transient-heading)
     (pcase (plist-get item :type)
       ('session
        (concat "  " project
                (if-let* ((branch (plist-get item :branch)))
                    (concat " " (propertize branch 'face 'agent-shell-pod-branch))
                  "")
                "  " (agent-shell-pod--icon (plist-get item :status))
                " " (plist-get item :title)))
       ('worktree
        (concat "  " project " " (propertize (or (plist-get item :branch) "")
                                             'face 'agent-shell-pod-branch)))
       ((or 'project 'new) (concat "  " project))
       (_ "")))))

;;;###autoload (autoload 'agent-shell-pod-sidebar-menu "agent-shell-pod" nil t)
(transient-define-prefix agent-shell-pod-sidebar-menu ()
  "All actions of the sidebar and dashboard."
  [:description agent-shell-pod--sidebar-menu-description
   ["Agent at point"
    ("RET" "Open" agent-shell-pod-visit :inapt-if-not agent-shell-pod--point-item-p)
    ("o" "Peek" agent-shell-pod-peek :inapt-if-not agent-shell-pod--point-session-p)
    ("O" "Open in other window" agent-shell-pod-visit-other-window
     :inapt-if-not agent-shell-pod--point-session-p)
    ("r" "Label" agent-shell-pod-rename :inapt-if-not agent-shell-pod--point-session-p)
    ("m" "Set mode" agent-shell-pod-set-mode :inapt-if-not agent-shell-pod--point-session-p)
    ("M" "Set model" agent-shell-pod-set-model :inapt-if-not agent-shell-pod--point-session-p)
    ("i" "Interrupt" agent-shell-pod-interrupt :inapt-if-not agent-shell-pod--point-session-p)
    ("R" "Restart" agent-shell-pod-restart :inapt-if-not agent-shell-pod--point-session-p)
    ("x" "Kill" agent-shell-pod-kill :inapt-if-not agent-shell-pod--point-session-p)]
   ["New"
    ("c" "Agent here" agent-shell-pod-new-session)
    ("w" "Agent in new worktree" agent-shell-pod-new-worktree-session
     :inapt-if-not agent-shell-pod--point-git-p)
    ("W" "Remove worktree" agent-shell-pod-remove-worktree
     :inapt-if-not agent-shell-pod--point-removable-worktree-p)
    ("+" "Add project" agent-shell-pod-add-project)
    ("-" "Hide project" agent-shell-pod-hide-project
     :inapt-if-not agent-shell-pod--point-hideable-project-p)]
   ["Project at point"
    ("f" "Find file" agent-shell-pod-find-file :inapt-if-not agent-shell-pod--point-item-p)
    ("d" "Dired" agent-shell-pod-dired :inapt-if-not agent-shell-pod--point-item-p)
    ("v" "Version control" agent-shell-pod-vc :inapt-if-not agent-shell-pod--point-item-p)
    ("P" "Switch project" agent-shell-pod-switch-project
     :inapt-if-not agent-shell-pod--point-item-p)]
   ["View"
    ("TAB" "Fold" agent-shell-pod-toggle-fold :inapt-if-not agent-shell-pod--point-foldable-p)
    ("J" "Next needing you" agent-shell-pod-next-attention
     :inapt-if-not agent-shell-pod--menu-attention-p)
    ("F" "Follow mode" agent-shell-pod-follow-mode)
    ("g" "Refresh" agent-shell-pod-refresh)
    ("D" "Dashboard" agent-shell-pod-dashboard)
    ("S" "Sidebar" agent-shell-pod)
    ("q" "Quit" agent-shell-pod-quit)]])

(defvar agent-shell-pod--keys-ready nil)

(defun agent-shell-pod--setup-evil ()
  "Give the sidebar and dashboard evil normal-state keys."
  (dolist (mode '(agent-shell-pod-sidebar-mode agent-shell-pod-dashboard-mode))
    (evil-set-initial-state mode 'normal))
  (dolist (map (list agent-shell-pod-sidebar-mode-map agent-shell-pod-dashboard-mode-map))
    (pcase-dolist (`(,key . ,command) (append agent-shell-pod--keys
                                             agent-shell-pod--evil-only-keys))
      (evil-define-key* 'normal map (kbd key) command)))
  (when (fboundp 'evil-normalize-keymaps)
    (evil-normalize-keymaps)))

(defun agent-shell-pod--setup-doom ()
  "Bind the Doom leader and localleader keys."
  (when (macrop 'map!)
    (when agent-shell-pod-leader-key
      (eval `(map! :leader :desc "Agents" ,agent-shell-pod-leader-key
                   #'agent-shell-pod-menu)
            t))
    (when agent-shell-pod-localleader-key
      (eval `(map! :map agent-shell-mode-map :localleader
                   :desc "Agent menu" ,agent-shell-pod-localleader-key
                   #'agent-shell-pod-session-menu)
            t))))

(defun agent-shell-pod-setup-keys ()
  "Set up evil and Doom key bindings once."
  (unless agent-shell-pod--keys-ready
    (setq agent-shell-pod--keys-ready t)
    (with-eval-after-load 'evil (agent-shell-pod--setup-evil))
    (agent-shell-pod--setup-doom)))

(provide 'agent-shell-pod)

;;; agent-shell-pod.el ends here
