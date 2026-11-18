;;; agent-shell-pod-telegram.el --- Telegram remote access for agent-shell-pod -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1") (agent-shell "0.24.2"))
;; Keywords: tools, convenience, comm

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Read replies, answer permissions and send prompts to agent-shell
;; sessions from a Telegram bot.  See README.md.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url)
(require 'url-util)
(require 'auth-source)
(require 'agent-shell-pod)

(declare-function agent-shell-prompt-queue "agent-shell-prompt-queue")

(defcustom agent-shell-pod-telegram-user-id nil
  "Numeric Telegram user id allowed to use the bot.  nil allows nobody."
  :type '(choice (const :tag "Nobody" nil) integer)
  :group 'agent-shell-pod)

(defcustom agent-shell-pod-telegram-only-when-away nil
  "When non-nil, send replies and permission prompts only when you are not looking."
  :type 'boolean
  :group 'agent-shell-pod)

;; shortcut: Telegram counts UTF-16 units, we count characters; emoji-heavy replies may need a lower limit.
(defconst agent-shell-pod-telegram--max-length 4096)
(defconst agent-shell-pod-telegram--max-messages 200)

(defconst agent-shell-pod-telegram--help
  "Send text to prompt the current session, or reply to a message to prompt its session.
/list  sessions
/use N  make N current
/stop [N]  interrupt
/new [N]  start an agent in the directory of N
/last [N]  resend the last reply")

(defvar agent-shell-pod-telegram--token nil)
(defvar agent-shell-pod-telegram--offset 0)
(defvar agent-shell-pod-telegram--generation 0)
(defvar agent-shell-pod-telegram--messages nil)
(defvar agent-shell-pod-telegram--current nil)
(defvar agent-shell-pod-telegram--next-number 0)
(defvar agent-shell-pod-telegram--next-key 0)
(defvar agent-shell-pod-telegram--pending (make-hash-table :test 'equal))
(defvar agent-shell-pod-telegram--previous-responder nil)

(defvar-local agent-shell-pod-telegram--number nil)
(defvar-local agent-shell-pod-telegram--reply "")
(defvar-local agent-shell-pod-telegram--last-reply nil)

(defun agent-shell-pod-telegram--api (method params &optional callback)
  "Call Telegram METHOD with PARAMS and pass the parsed reply to CALLBACK."
  (let ((url-request-method "POST")
        (url-request-extra-headers '(("Content-Type" . "application/json")))
        (url-request-data (encode-coding-string (json-encode params) 'utf-8)))
    (url-retrieve
     (format "https://api.telegram.org/bot%s/%s" agent-shell-pod-telegram--token method)
     (lambda (status)
       (let ((reply (unless (plist-get status :error)
                      (goto-char (point-min))
                      (when (re-search-forward "\r?\n\r?\n" nil t)
                        (ignore-errors
                          (json-parse-buffer :object-type 'alist
                                             :null-object nil :false-object nil))))))
         (when (and (plist-get status :error) (not (equal method "getUpdates")))
           (message "agent-shell-pod-telegram: %s failed: %S" method (plist-get status :error)))
         (kill-buffer)
         (when callback
           (condition-case err
               (funcall callback reply)
             (error (message "agent-shell-pod-telegram: %s" (error-message-string err)))))))
     nil t t)))

(defun agent-shell-pod-telegram--poll (generation)
  "Fetch and dispatch updates while GENERATION is the active poll."
  (when (= generation agent-shell-pod-telegram--generation)
    (condition-case nil
        (agent-shell-pod-telegram--api
         "getUpdates"
         `((offset . ,(1+ agent-shell-pod-telegram--offset))
           (timeout . 50)
           (allowed_updates . ["message" "callback_query"]))
         (lambda (reply)
           (when (= generation agent-shell-pod-telegram--generation)
             (if (not (eq (alist-get 'ok reply) t))
                 (run-at-time 5 nil #'agent-shell-pod-telegram--poll generation)
               (seq-doseq (update (alist-get 'result reply))
                 (setq agent-shell-pod-telegram--offset (alist-get 'update_id update))
                 (agent-shell-pod-telegram--dispatch update))
               (agent-shell-pod-telegram--poll generation)))))
      (error (run-at-time 5 nil #'agent-shell-pod-telegram--poll generation)))))

(defun agent-shell-pod-telegram--number-of (buffer)
  "Return the stable number of session BUFFER."
  (with-current-buffer buffer
    (or agent-shell-pod-telegram--number
        (setq agent-shell-pod-telegram--number
              (cl-incf agent-shell-pod-telegram--next-number)))))

(defun agent-shell-pod-telegram--label (buffer)
  "Return the title and project of session BUFFER."
  (let ((root (agent-shell-pod--root-for (buffer-local-value 'default-directory buffer))))
    (concat (truncate-string-to-width (agent-shell-pod--title buffer) 30 nil nil "…")
            (if root (concat " · " (agent-shell-pod--project-name root)) ""))))

(defun agent-shell-pod-telegram--tag (buffer)
  "Return the tag that starts messages about session BUFFER."
  (format "[%d %s]" (agent-shell-pod-telegram--number-of buffer)
          (agent-shell-pod-telegram--label buffer)))

(defun agent-shell-pod-telegram--split (text size)
  "Split TEXT into pieces of at most SIZE characters."
  (let (pieces)
    (while (> (length text) size)
      (push (substring text 0 size) pieces)
      (setq text (substring text size)))
    (nreverse (cons text pieces))))

(defun agent-shell-pod-telegram--remember (id buffer)
  "Remember that message ID is about session BUFFER."
  (push (cons id buffer) agent-shell-pod-telegram--messages)
  (setq agent-shell-pod-telegram--messages
        (seq-take agent-shell-pod-telegram--messages agent-shell-pod-telegram--max-messages)))

(defun agent-shell-pod-telegram--html-inline (text)
  "Convert inline code, bold, links and headings in TEXT to Telegram HTML."
  (let ((start 0) out)
    (while (string-match "`\\([^`\n]+\\)`" text start)
      (let ((before (substring text start (match-beginning 0)))
            (code (match-string 1 text)))
        (setq start (match-end 0))
        (push (agent-shell-pod-telegram--html-markup before) out)
        (push (concat "<code>" (url-insert-entities-in-string code) "</code>") out)))
    (push (agent-shell-pod-telegram--html-markup (substring text start)) out)
    (apply #'concat (nreverse out))))

(defun agent-shell-pod-telegram--html-markup (text)
  "Escape TEXT and convert bold, links and headings to Telegram HTML."
  (let ((html (url-insert-entities-in-string text)))
    (dolist (rule '(("\\*\\*\\([^*\n]+?\\)\\*\\*" . "<b>\\1</b>")
                    ("\\[\\([^]\n]+\\)\\](\\([^) \n]+\\))" . "<a href=\"\\2\">\\1</a>")
                    ("^#+ \\(.+\\)$" . "<b>\\1</b>")))
      (setq html (replace-regexp-in-string (car rule) (cdr rule) html t)))
    html))

(defun agent-shell-pod-telegram--html (text)
  "Convert the markdown subset in TEXT to Telegram HTML."
  (let ((start 0) out)
    (while (string-match "^```\\([^`\n]*\\)\n" text start)
      (let* ((before (substring text start (match-beginning 0)))
             (lang (string-trim (match-string 1 text)))
             (body-start (match-end 0))
             (close (string-match "^```[^\n]*\n?" text body-start))
             (body (substring text body-start (or close (length text)))))
        (setq start (if close (match-end 0) (length text)))
        (push (agent-shell-pod-telegram--html-inline before) out)
        (push (format "<pre><code%s>%s</code></pre>"
                      (if (string-empty-p lang) ""
                        (format " class=\"language-%s\"" (url-insert-entities-in-string lang)))
                      (url-insert-entities-in-string (string-remove-suffix "\n" body)))
              out)))
    (push (agent-shell-pod-telegram--html-inline (substring text start)) out)
    (apply #'concat (nreverse out))))

(defun agent-shell-pod-telegram--send-chunks (chunks tag buffer markup callback)
  "Send CHUNKS prefixed with TAG, then call CALLBACK with the last message id.
Each chunk goes as HTML and is resent as plain text when Telegram rejects it."
  (let ((params `((chat_id . ,agent-shell-pod-telegram-user-id)
                  ,@(and markup (null (cdr chunks)) `((reply_markup . ,markup)))))
        (continue
         (lambda (reply)
           (let ((id (map-nested-elt reply '(result message_id))))
             (when (and id buffer) (agent-shell-pod-telegram--remember id buffer))
             (cond ((cdr chunks)
                    (agent-shell-pod-telegram--send-chunks (cdr chunks) tag buffer markup callback))
                   ((and id callback) (funcall callback id)))))))
    (agent-shell-pod-telegram--api
     "sendMessage"
     `((text . ,(concat (url-insert-entities-in-string tag)
                        (agent-shell-pod-telegram--html (car chunks))))
       (parse_mode . "HTML")
       ,@params)
     (lambda (reply)
       (if (eq (alist-get 'ok reply) t)
           (funcall continue reply)
         (agent-shell-pod-telegram--api
          "sendMessage" `((text . ,(concat tag (car chunks))) ,@params) continue))))))

(defun agent-shell-pod-telegram--say (text &optional buffer markup callback)
  "Send TEXT, tagged with session BUFFER when given.
MARKUP goes on the last message and CALLBACK gets its id."
  (let ((tag (if buffer (concat (agent-shell-pod-telegram--tag buffer) "\n") "")))
    (when buffer (setq agent-shell-pod-telegram--current buffer))
    (agent-shell-pod-telegram--send-chunks
     (agent-shell-pod-telegram--split
      text (- agent-shell-pod-telegram--max-length (length tag)))
     tag buffer markup callback)))

(defun agent-shell-pod-telegram--current ()
  "Return the session that untargeted messages go to."
  (if (agent-shell-pod--session-p agent-shell-pod-telegram--current)
      agent-shell-pod-telegram--current
    (car (agent-shell-pod--sessions))))

(defun agent-shell-pod-telegram--session (arg)
  "Return the session numbered ARG, or the current one when ARG is nil."
  (or (if arg
          (seq-find (lambda (b) (equal (agent-shell-pod-telegram--number-of b)
                                       (string-to-number arg)))
                    (agent-shell-pod--sessions))
        (agent-shell-pod-telegram--current))
      (user-error "No session %s.  Send /list" (or arg ""))))

(defun agent-shell-pod-telegram--list (_arg)
  "Send the list of sessions."
  (let ((current (agent-shell-pod-telegram--current))
        (sessions (sort (agent-shell-pod--sessions)
                        (lambda (a b) (< (agent-shell-pod-telegram--number-of a)
                                         (agent-shell-pod-telegram--number-of b))))))
    (agent-shell-pod-telegram--say
     (if sessions
         (mapconcat (lambda (b)
                      (format "%d %s %s%s" (agent-shell-pod-telegram--number-of b)
                              (alist-get (agent-shell-pod--status b) agent-shell-pod-status-icons)
                              (agent-shell-pod-telegram--label b)
                              (if (eq b current) " ←" "")))
                    sessions "\n")
       "No sessions")
     nil
     (and sessions
          `((inline_keyboard
             . ,(vconcat (mapcar (lambda (b)
                                   (let ((n (agent-shell-pod-telegram--number-of b)))
                                     (vector `((text . ,(format "%d %s" n (agent-shell-pod-telegram--label b)))
                                               (callback_data . ,(format "use:%d" n))))))
                                 sessions))))))))

(defun agent-shell-pod-telegram--use (arg)
  "Make session ARG current."
  (agent-shell-pod-telegram--say "Now using this session"
                                 (agent-shell-pod-telegram--session arg)))

(defun agent-shell-pod-telegram--stop (arg)
  "Interrupt session ARG."
  (let ((buffer (agent-shell-pod-telegram--session arg)))
    (with-current-buffer buffer (agent-shell-interrupt t))
    (agent-shell-pod-telegram--say "Stopped" buffer)))

(defun agent-shell-pod-telegram--new (arg)
  "Start an agent in the directory of session ARG."
  (let ((dir (buffer-local-value 'default-directory (agent-shell-pod-telegram--session arg))))
    (unless (agent-shell--auto-preferred-config)
      (user-error "Set agent-shell-preferred-agent-config to start agents from Telegram"))
    (let ((buffer (agent-shell-pod--start-in dir)))
      (if (agent-shell-pod--session-p buffer)
          (agent-shell-pod-telegram--say "Started" buffer)
        (agent-shell-pod-telegram--say (format "Started in %s" (abbreviate-file-name dir)))))))

(defun agent-shell-pod-telegram--last (arg)
  "Resend the last reply of session ARG."
  (let ((buffer (agent-shell-pod-telegram--session arg)))
    (agent-shell-pod-telegram--say
     (or (buffer-local-value 'agent-shell-pod-telegram--last-reply buffer) "No reply yet")
     buffer)))

(defconst agent-shell-pod-telegram--commands
  '(("list" . agent-shell-pod-telegram--list)
    ("use" . agent-shell-pod-telegram--use)
    ("stop" . agent-shell-pod-telegram--stop)
    ("new" . agent-shell-pod-telegram--new)
    ("last" . agent-shell-pod-telegram--last)
    ("help" . agent-shell-pod-telegram--help)
    ("start" . agent-shell-pod-telegram--help)))

(defun agent-shell-pod-telegram--help (_arg)
  "Send the command list."
  (agent-shell-pod-telegram--say agent-shell-pod-telegram--help))

(defun agent-shell-pod-telegram--on-text (message)
  "Run the command in MESSAGE, or send its text as a prompt."
  (let-alist message
    (let* ((command (and (string-match "\\`/\\([a-z]+\\)\\(?:@[[:alnum:]_]+\\)?\\(?:[ \t]+\\(.+\\)\\)?\\'"
                                       .text)
                         (assoc (match-string 1 .text) agent-shell-pod-telegram--commands)))
           (arg (and command (match-string 2 .text))))
      (if command
          (funcall (cdr command) (and arg (string-trim arg)))
        (let ((buffer (or (cdr (assq .reply_to_message.message_id agent-shell-pod-telegram--messages))
                          (agent-shell-pod-telegram--current)
                          (user-error "No session.  Start one in Emacs"))))
          (setq agent-shell-pod-telegram--current buffer)
          (with-current-buffer buffer (agent-shell-prompt-queue .text)))))))

(defun agent-shell-pod-telegram--on-callback (query)
  "Answer the permission or session chosen with the button in QUERY."
  (let-alist query
    (let* ((data (or .data ""))
           (parts (and (string-match "\\`\\([^:]+\\):\\(.*\\)\\'" data)
                       (cons (match-string 1 data) (match-string 2 data))))
           (pending (and parts (gethash (car parts) agent-shell-pod-telegram--pending))))
      (cond
       ((equal (car parts) "use")
        (agent-shell-pod-telegram--api "answerCallbackQuery" `((callback_query_id . ,.id)))
        (agent-shell-pod-telegram--use (cdr parts)))
       ((not (and pending (buffer-live-p (plist-get pending :buffer))))
        (agent-shell-pod-telegram--api "answerCallbackQuery"
                                       `((callback_query_id . ,.id) (text . "Expired"))))
       (t
        (remhash (car parts) agent-shell-pod-telegram--pending)
        (funcall (plist-get pending :respond) (cdr parts))
        (let ((label (or (cdr (assoc (cdr parts) (plist-get pending :options))) (cdr parts))))
          (agent-shell-pod-telegram--api "answerCallbackQuery"
                                         `((callback_query_id . ,.id) (text . ,label)))
          (agent-shell-pod-telegram--api "editMessageText"
                                         `((chat_id . ,agent-shell-pod-telegram-user-id)
                                           (message_id . ,.message.message_id)
                                           (text . ,(concat (plist-get pending :text)
                                                            "\n\n→ " label))))))))))

(defun agent-shell-pod-telegram--dispatch (update)
  "Handle UPDATE from Telegram when it comes from the allowed user."
  (let-alist update
    (when (and agent-shell-pod-telegram-user-id
               (eql (or .message.from.id .callback_query.from.id)
                    agent-shell-pod-telegram-user-id))
      (condition-case err
          (cond (.callback_query (agent-shell-pod-telegram--on-callback .callback_query))
                (.message.text (agent-shell-pod-telegram--on-text .message)))
        (error (agent-shell-pod-telegram--say (error-message-string err)))))))

(defun agent-shell-pod-telegram--permission-buffer (tool-call)
  "Return the session that owns TOOL-CALL."
  (seq-find (lambda (b)
              (seq-some (lambda (tc) (eq tc tool-call))
                        (map-values (map-elt (agent-shell-pod--state b) :tool-calls))))
            (agent-shell-pod--sessions)))

(defun agent-shell-pod-telegram--offer (permission)
  "Send PERMISSION to Telegram with a button per option."
  (let* ((tool-call (map-elt permission :tool-call))
         (buffer (agent-shell-pod-telegram--permission-buffer tool-call)))
    (when (and buffer
               (not (and agent-shell-pod-telegram-only-when-away
                         (agent-shell-pod--looking-at-p buffer))))
      (let* ((key (number-to-string (cl-incf agent-shell-pod-telegram--next-key)))
             (options (mapcar (lambda (o) (cons (map-elt o :option-id)
                                                (substring-no-properties (map-elt o :label))))
                              (map-elt permission :options)))
             (body (format "Permission: %s%s" (or (map-elt tool-call :title) "tool call")
                           (if-let* ((kind (map-elt tool-call :kind))) (format " (%s)" kind) "")))
             (pending (list :buffer buffer
                            :respond (map-elt permission :respond)
                            :request-id (map-elt tool-call :permission-request-id)
                            :options options
                            :text (concat (agent-shell-pod-telegram--tag buffer) "\n" body)
                            :message-id nil)))
        (puthash key pending agent-shell-pod-telegram--pending)
        (agent-shell-pod-telegram--say
         body buffer
         `((inline_keyboard
            . ,(vconcat (mapcar (lambda (o)
                                  (vector `((text . ,(cdr o))
                                            (callback_data . ,(format "%s:%s" key (car o))))))
                                options))))
         (lambda (id) (plist-put pending :message-id id)))))))

(defun agent-shell-pod-telegram--responder (permission)
  "Offer PERMISSION on Telegram and still show the Emacs prompt.
A previous responder that handles it wins."
  (or (and (functionp agent-shell-pod-telegram--previous-responder)
           (funcall agent-shell-pod-telegram--previous-responder permission))
      (progn
        (condition-case err
            (agent-shell-pod-telegram--offer permission)
          (error (message "agent-shell-pod-telegram: %s" (error-message-string err))))
        nil)))

(defun agent-shell-pod-telegram--on-event (event)
  "Forward agent-shell EVENT of the current session to Telegram."
  (let ((buffer (current-buffer))
        (data (map-elt event :data)))
    (pcase (map-elt event :event)
      ('input-submitted (setq agent-shell-pod-telegram--reply ""))
      ('agent-message-chunk
       (when-let* ((chunk (map-elt data :text-chunk)))
         (setq agent-shell-pod-telegram--reply (concat agent-shell-pod-telegram--reply chunk))))
      ('turn-complete
       (let ((text (string-trim agent-shell-pod-telegram--reply)))
         (setq agent-shell-pod-telegram--reply "")
         (unless (string-empty-p text)
           (setq agent-shell-pod-telegram--last-reply text))
         (unless (and agent-shell-pod-telegram-only-when-away
                      (agent-shell-pod--looking-at-p buffer))
           (agent-shell-pod-telegram--say (if (string-empty-p text) "Done" text) buffer))))
      ('error
       (agent-shell-pod-telegram--say
        (format "Error: %s" (or (map-elt data :message) "request failed")) buffer))
      ('permission-response
       (maphash (lambda (key pending)
                  (when (and (eq (plist-get pending :buffer) buffer)
                             (equal (plist-get pending :request-id) (map-elt data :request-id)))
                    (remhash key agent-shell-pod-telegram--pending)
                    (when-let* ((id (plist-get pending :message-id)))
                      (agent-shell-pod-telegram--api
                       "editMessageText"
                       `((chat_id . ,agent-shell-pod-telegram-user-id)
                         (message_id . ,id)
                         (text . ,(concat (plist-get pending :text) "\n\n→ answered in Emacs")))))))
                agent-shell-pod-telegram--pending)))))

;;;###autoload
(define-minor-mode agent-shell-pod-telegram-mode
  "Use agent-shell sessions from a Telegram bot."
  :global t
  :group 'agent-shell-pod
  (cl-incf agent-shell-pod-telegram--generation)
  (if agent-shell-pod-telegram-mode
      (progn
        (unless agent-shell-pod-telegram-user-id
          (setq agent-shell-pod-telegram-mode nil)
          (user-error "Set `agent-shell-pod-telegram-user-id' first"))
        (setq agent-shell-pod-telegram--token
              (condition-case err
                  (auth-source-pick-first-password :host "api.telegram.org")
                (error (setq agent-shell-pod-telegram-mode nil)
                       (signal (car err) (cdr err)))))
        (unless agent-shell-pod-telegram--token
          (setq agent-shell-pod-telegram-mode nil)
          (user-error "No password for api.telegram.org in auth-source"))
        (unless agent-shell-pod-mode (agent-shell-pod-mode 1))
        (unless (eq agent-shell-permission-responder-function
                    #'agent-shell-pod-telegram--responder)
          (setq agent-shell-pod-telegram--previous-responder
                agent-shell-permission-responder-function
                agent-shell-permission-responder-function
                #'agent-shell-pod-telegram--responder))
        (add-hook 'agent-shell-pod-event-functions #'agent-shell-pod-telegram--on-event)
        (agent-shell-pod-telegram--poll agent-shell-pod-telegram--generation))
    (when (eq agent-shell-permission-responder-function #'agent-shell-pod-telegram--responder)
      (setq agent-shell-permission-responder-function
            agent-shell-pod-telegram--previous-responder))
    (setq agent-shell-pod-telegram--previous-responder nil
          agent-shell-pod-telegram--token nil)
    (remove-hook 'agent-shell-pod-event-functions #'agent-shell-pod-telegram--on-event)
    (clrhash agent-shell-pod-telegram--pending)))

(provide 'agent-shell-pod-telegram)

;;; agent-shell-pod-telegram.el ends here
