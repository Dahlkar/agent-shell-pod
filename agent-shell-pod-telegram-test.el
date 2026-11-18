;;; agent-shell-pod-telegram-test.el --- Tests for agent-shell-pod-telegram -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'agent-shell-pod-test)
(require 'agent-shell-pod-telegram)

(defmacro agent-shell-pod-telegram-test--with-env (&rest body)
  (declare (indent 0))
  `(agent-shell-pod-test--with-env
     (let ((agent-shell-pod-telegram-user-id 42)
           (agent-shell-pod-telegram-only-when-away nil)
           (agent-shell-pod-telegram--messages nil)
           (agent-shell-pod-telegram--current nil)
           (agent-shell-pod-telegram--next-number 0)
           (agent-shell-pod-telegram--next-key 0)
           (agent-shell-pod-telegram--pending (make-hash-table :test 'equal))
           (calls nil))
       (cl-letf (((symbol-function 'agent-shell-pod-telegram--api)
                  (lambda (method params &optional callback)
                    (push (cons method params) calls)
                    (when callback
                      (funcall callback `((ok . t)
                                          (result (message_id . ,(+ 500 (length calls)))))))))
                 ((symbol-function 'agent-shell-pod--looking-at-p) #'ignore))
         ,@body))))

(defun agent-shell-pod-telegram-test--texts (calls)
  (mapcar (lambda (c) (cons (car c) (alist-get 'text (cdr c)))) (reverse calls)))

(defun agent-shell-pod-telegram-test--sessions (tmp)
  (make-directory (expand-file-name "alpha" tmp))
  (make-directory (expand-file-name "beta" tmp))
  (let ((a (agent-shell-pod-test--session (expand-file-name "alpha" tmp) "Alpha"))
        (b (agent-shell-pod-test--session (expand-file-name "beta" tmp) "Beta")))
    (agent-shell-pod-telegram--number-of a)
    (agent-shell-pod-telegram--number-of b)
    (list a b)))

(ert-deftest agent-shell-pod-telegram-test-dispatch-text ()
  (dolist (case
           '(;; a stranger is ignored
             (7 "hi" nil nil nil "Alpha")
             ;; plain text prompts the current session
             (42 "hi" nil ((prompt "Alpha" "hi")) nil "Alpha")
             ;; a reply prompts the session of the replied message
             (42 "hi" 100 ((prompt "Beta" "hi")) nil "Beta")
             ;; unknown commands go to the agent
             (42 "/compact" nil ((prompt "Alpha" "/compact")) nil "Alpha")
             ;; /use switches the current session
             (42 "/use 2" nil nil ("[2 Beta]\nNow using this session") "Beta")
             ;; an unknown number is reported
             (42 "/use 9" nil nil ("No session 9.  Send /list") "Alpha")
             ;; /stop N interrupts that session without asking
             (42 "/stop 2" nil ((interrupt "Beta" t)) ("[2 Beta]\nStopped") "Beta")
             ;; /stop alone interrupts the current session
             (42 "/stop@pod_bot" nil ((interrupt "Alpha" t)) ("[1 Alpha]\nStopped") "Alpha")
             ;; /new starts in the directory of the session
             (42 "/new 2" nil ((start "beta/")) ("[3 Gamma]\nStarted") "Gamma")
             ;; /list shows every session and marks the current one
             (42 "/list" nil nil ("1 ● Alpha ←\n2 ● Beta") "Alpha")
             ;; /last resends the last reply
             (42 "/last 2" nil nil ("[2 Beta]\nAll done") "Beta")))
    (pcase-let ((`(,from ,text ,reply ,actions ,sent ,current) case))
      (agent-shell-pod-telegram-test--with-env
        (pcase-let* ((`(,a ,b) (agent-shell-pod-telegram-test--sessions tmp))
                     (log nil))
          (with-current-buffer b (setq agent-shell-pod-telegram--last-reply "All done"))
          (setq agent-shell-pod-telegram--messages (list (cons 100 b))
                agent-shell-pod-telegram--current a)
          (cl-letf (((symbol-function 'agent-shell-prompt-queue)
                     (lambda (prompt) (push (list 'prompt (agent-shell-pod--title (current-buffer)) prompt) log)))
                    ((symbol-function 'agent-shell-interrupt)
                     (lambda (&optional force) (push (list 'interrupt (agent-shell-pod--title (current-buffer)) force) log)))
                    ((symbol-function 'agent-shell--auto-preferred-config) (lambda () '((:identifier . claude))))
                    ((symbol-function 'agent-shell-pod--start-in)
                     (lambda (dir)
                       (push (list 'start (file-relative-name dir tmp)) log)
                       (agent-shell-pod-test--session dir "Gamma"))))
            (agent-shell-pod-telegram--dispatch
             `((update_id . 1)
               (message (message_id . 1) (from (id . ,from)) (text . ,text)
                        ,@(when reply `((reply_to_message (message_id . ,reply))))))))
          (should (equal (reverse log) actions))
          (should (equal (mapcar #'cdr (agent-shell-pod-telegram-test--texts calls)) sent))
          (should (equal (agent-shell-pod--title (agent-shell-pod-telegram--current)) current)))))))

(ert-deftest agent-shell-pod-telegram-test-new-needs-preferred-config ()
  (agent-shell-pod-telegram-test--with-env
    (agent-shell-pod-telegram-test--sessions tmp)
    (cl-letf (((symbol-function 'agent-shell--auto-preferred-config) #'ignore)
              ((symbol-function 'agent-shell-pod--start-in) (lambda (_) (error "Should not start"))))
      (agent-shell-pod-telegram--dispatch
       '((update_id . 1) (message (message_id . 1) (from (id . 42)) (text . "/new")))))
    (should (equal (agent-shell-pod-telegram-test--texts calls)
                   '(("sendMessage" . "Set agent-shell-preferred-agent-config to start agents from Telegram"))))))

(ert-deftest agent-shell-pod-telegram-test-callback ()
  (dolist (case
           '(;; a known key answers the agent with the option
             (42 "1:allow" ("allow")
                 (("answerCallbackQuery" . "Allow (y)")
                  ("editMessageText" . "[1 Alpha]\nPermission: rm\n\n→ Allow (y)")))
             ;; an unknown or stale key just says it expired
             (42 "9:allow" nil (("answerCallbackQuery" . "Expired")))
             ;; malformed data is treated as expired
             (42 "nonsense" nil (("answerCallbackQuery" . "Expired")))
             ;; a stranger's tap is ignored
             (7 "1:allow" nil nil)))
    (pcase-let ((`(,from ,data ,responded ,sent) case))
      (agent-shell-pod-telegram-test--with-env
        (let ((a (car (agent-shell-pod-telegram-test--sessions tmp)))
              (got nil))
          (puthash "1" (list :buffer a
                             :respond (lambda (id) (push id got))
                             :options '(("allow" . "Allow (y)"))
                             :text "[1 Alpha]\nPermission: rm")
                   agent-shell-pod-telegram--pending)
          (agent-shell-pod-telegram--dispatch
           `((update_id . 1)
             (callback_query (id . "q1") (from (id . ,from)) (data . ,data)
                             (message (message_id . 77)))))
          (should (equal got responded))
          (should (equal (agent-shell-pod-telegram-test--texts calls) sent))
          (should (eq (null (gethash "1" agent-shell-pod-telegram--pending)) (and responded t))))))))

(ert-deftest agent-shell-pod-telegram-test-responder ()
  (dolist (case
           '(;; without a previous responder, offer buttons and keep the Emacs prompt
             (nil nil 1)
             ;; a previous responder that handles the request wins
             (t t 0)))
    (pcase-let ((`(,previous ,expected ,sends) case))
      (agent-shell-pod-telegram-test--with-env
        (let* ((a (car (agent-shell-pod-telegram-test--sessions tmp)))
               (tool-call (list (cons :title "rm dist") (cons :kind "execute")
                                (cons :permission-request-id 7)))
               (agent-shell-pod-telegram--previous-responder (lambda (_) previous)))
          (with-current-buffer a
            (push (cons :tool-calls (list (cons "tc1" tool-call))) agent-shell--state))
          (should (eq (agent-shell-pod-telegram--responder
                       `((:tool-call . ,tool-call)
                         (:options ((:option-id . "allow") (:label . "Allow (y)"))
                                   ((:option-id . "reject") (:label . "Reject (n)")))
                         (:respond . ignore)))
                      expected))
          (should (= (length calls) sends))
          (when (> sends 0)
            (let ((params (cdar calls)))
              (should (equal (alist-get 'text params) "[1 Alpha]\nPermission: rm dist (execute)"))
              (should (equal (alist-get 'reply_markup params)
                             '((inline_keyboard
                                . [[((text . "Allow (y)") (callback_data . "1:allow"))]
                                   [((text . "Reject (n)") (callback_data . "1:reject"))]])))))
            (should (equal (plist-get (gethash "1" agent-shell-pod-telegram--pending) :message-id) 501))
            (with-current-buffer a
              (agent-shell-pod-telegram--on-event
               '((:event . permission-response) (:data (:request-id . 7)))))
            (should (equal (car (agent-shell-pod-telegram-test--texts (list (car calls))))
                           '("editMessageText"
                             . "[1 Alpha]\nPermission: rm dist (execute)\n\n→ answered in Emacs")))
            (should (= 0 (hash-table-count agent-shell-pod-telegram--pending)))))))))

(ert-deftest agent-shell-pod-telegram-test-turn-output ()
  (dolist (case
           '(;; replies are sent by default
             (nil nil ("Hel" "lo") ("[1 Alpha]\nHello"))
             ;; a turn without text still says it is done
             (nil nil nil ("[1 Alpha]\nDone"))
             ;; only-when-away holds replies back while you look
             (t t ("Hello") nil)
             ;; only-when-away still sends while you are away
             (t nil ("Hello") ("[1 Alpha]\nHello"))))
    (pcase-let ((`(,away ,looking ,chunks ,sent) case))
      (agent-shell-pod-telegram-test--with-env
        (let ((a (car (agent-shell-pod-telegram-test--sessions tmp)))
              (agent-shell-pod-telegram-only-when-away away))
          (cl-letf (((symbol-function 'agent-shell-pod--looking-at-p) (lambda (_) looking)))
            (with-current-buffer a
              (setq agent-shell-pod-telegram--reply "stale")
              (agent-shell-pod-telegram--on-event '((:event . input-submitted)))
              (dolist (chunk chunks)
                (agent-shell-pod-telegram--on-event
                 `((:event . agent-message-chunk) (:data (:text-chunk . ,chunk)))))
              (agent-shell-pod-telegram--on-event '((:event . turn-complete)))
              (should (equal agent-shell-pod-telegram--last-reply (and chunks (apply #'concat chunks))))))
          (should (equal (mapcar #'cdr (agent-shell-pod-telegram-test--texts calls)) sent)))))))

(ert-deftest agent-shell-pod-telegram-test-split ()
  (dolist (case '((0 (0)) (4096 (4096)) (4097 (4096 1)) (8192 (4096 4096))))
    (should (equal (mapcar #'length (agent-shell-pod-telegram--split
                                     (make-string (car case) ?x) 4096))
                   (cadr case)))))

(ert-deftest agent-shell-pod-telegram-test-long-reply-is-split-with-tags ()
  (agent-shell-pod-telegram-test--with-env
    (let ((a (car (agent-shell-pod-telegram-test--sessions tmp))))
      (agent-shell-pod-telegram--say (make-string 4096 ?x) a)
      (let ((texts (mapcar #'cdr (agent-shell-pod-telegram-test--texts calls))))
        (should (equal (mapcar #'length texts) '(4096 20)))
        (should (seq-every-p (lambda (s) (string-prefix-p "[1 Alpha]\n" s)) texts)))
      (should (equal agent-shell-pod-telegram--messages (list (cons 502 a) (cons 501 a)))))))

(ert-deftest agent-shell-pod-telegram-test-mode ()
  (let ((agent-shell-pod-telegram-mode nil)
        (agent-shell-pod-mode t)
        (agent-shell-pod-event-functions nil)
        (agent-shell-permission-responder-function #'agent-shell-permission-allow-always)
        (agent-shell-pod-telegram--previous-responder nil)
        (polled nil))
    (cl-letf (((symbol-function 'auth-source-pick-first-password) (lambda (&rest _) "token"))
              ((symbol-function 'agent-shell-pod-telegram--poll) (lambda (g) (push g polled))))
      (let ((agent-shell-pod-telegram-user-id nil))
        (should-error (agent-shell-pod-telegram-mode 1) :type 'user-error)
        (should-not agent-shell-pod-telegram-mode)
        (should-not polled))
      (let ((agent-shell-pod-telegram-user-id 42))
        (agent-shell-pod-telegram-mode 1)
        (should (eq agent-shell-permission-responder-function #'agent-shell-pod-telegram--responder))
        (should (memq #'agent-shell-pod-telegram--on-event agent-shell-pod-event-functions))
        (should (equal polled (list agent-shell-pod-telegram--generation)))
        (agent-shell-pod-telegram-mode -1)
        (should (eq agent-shell-permission-responder-function #'agent-shell-permission-allow-always))
        (should-not agent-shell-pod-event-functions)
        (should-not agent-shell-pod-telegram--token)))))

(provide 'agent-shell-pod-telegram-test)

;;; agent-shell-pod-telegram-test.el ends here
