;;; deathless-store.el --- Event-fed session store for deathless -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The model behind the deathless dashboard.  It tracks every
;; `agent-shell' buffer and keeps one `deathless-session' record per
;; buffer.
;;
;; agent-shell already pushes everything a dashboard needs as events
;; (see `agent-shell-subscribe-to'): a prompt was submitted, a tool call
;; changed, a permission is wanted, the turn is over, the shell is gone.
;; The store subscribes to each shell, treats every event as a signal to
;; re-read that shell's state, and keeps the few facts the shell itself
;; forgets: when the turn started, the last tool call, the last error,
;; and whether a finished turn has been seen yet.
;;
;; Consumers listen on `deathless-store-change-functions'.  Nothing here
;; polls, and nothing here knows about the UI.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)

(defvar agent-shell--state)
(defvar agent-shell-mode-hook)
(declare-function agent-shell-subscribe-to "agent-shell")
(declare-function agent-shell-unsubscribe "agent-shell")
(declare-function agent-shell-buffers "agent-shell")
(declare-function agent-shell--resolve-session-mode-name "agent-shell")
(declare-function agent-shell--send-permission-response "agent-shell")
(declare-function shell-maker-busy "shell-maker")

;;;; Session record

(cl-defstruct (deathless-session (:constructor deathless-session--create)
                                 (:copier nil))
  "What deathless knows about one agent shell."
  (buffer nil :documentation "The `agent-shell' buffer.")
  (created nil :documentation "When deathless started tracking it.")
  (agent nil :documentation "Agent display name, e.g. \"Claude\".")
  (title nil :documentation "Session title, or the first prompt.")
  (model nil :documentation "Current model display name.")
  (mode nil :documentation "Current session mode display name.")
  (cwd nil :documentation "Working directory, abbreviated.")
  (usage nil :documentation "agent-shell usage alist.")
  (alive t :documentation "Non-nil while the shell and agent processes run.")
  (ready nil :documentation "Non-nil once the ACP session is up.")
  (permissions nil :documentation "Pending permission plists, oldest first.")
  (turn-start nil :documentation "`float-time' the running turn began.")
  (finished-at nil :documentation "`float-time' the last turn ended.")
  (stop-reason nil :documentation "ACP stop reason of the last turn.")
  (last-tool nil :documentation "Plist (:title :kind :status) of the last tool call.")
  (error nil :documentation "Message of the last error in this turn.")
  (unseen nil :documentation "Non-nil when a turn ended while out of view.")
  (subscription nil :documentation "agent-shell subscription token."))

(defun deathless-session-status (session)
  "Return the status of SESSION as a symbol.

One of `exited', `blocked' (waiting on a permission), `working',
`starting', `failed' (the last turn hit an error), `stopped' (the
last turn ended for a reason other than finishing), `done' (a turn
finished out of view and has not been looked at) or `ready'."
  (let ((reason (deathless-session-stop-reason session)))
    (cond
     ((not (deathless-session-alive session)) 'exited)
     ((deathless-session-permissions session) 'blocked)
     ((deathless-session-turn-start session) 'working)
     ((not (deathless-session-ready session)) 'starting)
     ((deathless-session-error session) 'failed)
     ((and reason (not (equal reason "end_turn"))) 'stopped)
     ((deathless-session-unseen session) 'done)
     (t 'ready))))

(defun deathless-session-needs-attention-p (session)
  "Return non-nil when SESSION is waiting on the user."
  (memq (deathless-session-status session) '(blocked done failed)))

;;;; Store

(defvar deathless-store--sessions (make-hash-table :test #'eq)
  "Map of shell buffer to its `deathless-session'.")

(defvar deathless-store--counter 0
  "Tie-breaker that keeps creation order stable within one `float-time'.")

(defvar deathless-store-change-functions nil
  "Abnormal hook run after a session changes.
Each function is called with the shell buffer that changed, or nil
when the set of sessions changed as a whole.")

(defun deathless-store-sessions ()
  "Return the tracked sessions, oldest first."
  (sort (hash-table-values deathless-store--sessions)
        (lambda (a b)
          (< (car (deathless-session-created a))
             (car (deathless-session-created b))))))

(defun deathless-store-get (buffer)
  "Return the session tracked for BUFFER, or nil."
  (gethash buffer deathless-store--sessions))

(defun deathless-store--notify (buffer)
  "Tell listeners that BUFFER's session changed."
  (run-hook-with-args 'deathless-store-change-functions buffer))

;;;; Reading agent-shell state
;;
;; agent-shell keeps its state in the buffer-local alist
;; `agent-shell--state'.  Every read of it goes through this section,
;; so a change upstream breaks one place.

(defun deathless-store--state (buffer)
  "Return BUFFER's agent-shell state alist, or nil."
  (and (buffer-live-p buffer)
       (local-variable-p 'agent-shell--state buffer)
       (buffer-local-value 'agent-shell--state buffer)))

(defun deathless-store--live-process-p (proc)
  "Return non-nil when PROC is a process that is still running."
  (and (processp proc) (process-live-p proc)))

(defun deathless-store--alive-p (buffer state)
  "Return non-nil when BUFFER's shell and agent processes both run.
STATE is BUFFER's agent-shell state.  A shell whose agent has not
been started yet counts as alive."
  (and (buffer-live-p buffer)
       (deathless-store--live-process-p (get-buffer-process buffer))
       (let ((client (map-elt state :client)))
         (or (null client)
             (deathless-store--live-process-p (map-elt client :process))))))

(defun deathless-store--model-name (state)
  "Return the display name of STATE's current model, or nil."
  (when-let* ((id (map-nested-elt state '(:session :model-id))))
    (or (seq-some (lambda (model)
                    (and (equal (map-elt model :model-id) id)
                         (map-elt model :name)))
                  (map-nested-elt state '(:session :models)))
        id)))

(defun deathless-store--mode-name (state)
  "Return the display name of STATE's current session mode, or nil."
  (when-let* ((id (map-nested-elt state '(:session :mode-id))))
    (or (and (fboundp 'agent-shell--resolve-session-mode-name)
             (ignore-errors
               (agent-shell--resolve-session-mode-name
                id (map-nested-elt state '(:session :modes)))))
        id)))

(defun deathless-store--permissions (state)
  "Return STATE's pending permission requests as plists, oldest first.
Each plist has :tool-call-id, :request-id, :title, :kind and
:actions, the agent-shell permission actions (alists with
:option, :kind and :option-id)."
  (let (result)
    (map-do (lambda (tool-call-id tool-call)
              (when-let* ((request-id (map-elt tool-call :permission-request-id)))
                (push (list :tool-call-id tool-call-id
                            :request-id request-id
                            :title (map-elt tool-call :title)
                            :kind (map-elt tool-call :kind)
                            :actions (map-elt tool-call :permission-actions))
                      result)))
            (map-elt state :tool-calls))
    ;; `push' reversed the tool calls, which agent-shell keeps newest first.
    result))

(defun deathless-store--agent-name (state)
  "Return the agent display name recorded in STATE."
  (or (map-nested-elt state '(:agent-config :mode-line-name))
      (map-nested-elt state '(:agent-config :buffer-name))
      "Agent"))

(defun deathless-store--busy-p (buffer)
  "Return non-nil when shell-maker reports BUFFER as busy."
  (and (fboundp 'shell-maker-busy)
       (with-current-buffer buffer
         (ignore-errors (shell-maker-busy)))))

(defun deathless-store--sync (session)
  "Refresh SESSION from its buffer's agent-shell state."
  (let* ((buffer (deathless-session-buffer session))
         (state (deathless-store--state buffer)))
    (if (not state)
        (setf (deathless-session-alive session) nil
              (deathless-session-permissions session) nil
              (deathless-session-turn-start session) nil)
      (setf (deathless-session-agent session) (deathless-store--agent-name state)
            (deathless-session-title session) (map-nested-elt state '(:session :title))
            (deathless-session-model session) (deathless-store--model-name state)
            (deathless-session-mode session) (deathless-store--mode-name state)
            (deathless-session-cwd session)
            (abbreviate-file-name
             (directory-file-name (buffer-local-value 'default-directory buffer)))
            (deathless-session-usage session) (map-elt state :usage)
            (deathless-session-alive session) (deathless-store--alive-p buffer state)
            (deathless-session-ready session)
            (and (map-elt state :initialized)
                 (map-nested-elt state '(:session :id))
                 t)
            (deathless-session-permissions session) (deathless-store--permissions state))
      (unless (deathless-session-alive session)
        (setf (deathless-session-turn-start session) nil
              (deathless-session-permissions session) nil)))
    session))

;;;; Events

(defun deathless-store--apply-event (session event)
  "Fold agent-shell EVENT into SESSION.
Return non-nil when SESSION may have changed."
  (let ((data (map-elt event :data))
        (now (float-time)))
    (pcase (map-elt event :event)
      ;; Streamed text arrives once per chunk; nothing shown depends on it.
      ('agent-message-chunk nil)
      ('input-submitted
       (setf (deathless-session-turn-start session) now
             (deathless-session-stop-reason session) nil
             (deathless-session-error session) nil
             (deathless-session-last-tool session) nil
             (deathless-session-unseen session) nil)
       t)
      ('tool-call-update
       (let ((tool-call (map-elt data :tool-call)))
         (when (map-elt tool-call :title)
           (setf (deathless-session-last-tool session)
                 (list :title (map-elt tool-call :title)
                       :kind (map-elt tool-call :kind)
                       :status (map-elt tool-call :status)))))
       t)
      ('turn-complete
       (setf (deathless-session-turn-start session) nil
             (deathless-session-finished-at session) now
             (deathless-session-stop-reason session) (map-elt data :stop-reason)
             (deathless-session-unseen session)
             (not (get-buffer-window (deathless-session-buffer session) 'visible)))
       t)
      ('error
       (setf (deathless-session-error session)
             (or (map-elt data :message) "Request failed"))
       t)
      (_ t))))

(defun deathless-store--on-event (buffer event)
  "Handle agent-shell EVENT emitted by shell BUFFER."
  (condition-case-unless-debug err
      (if (eq (map-elt event :event) 'clean-up)
          (deathless-store-untrack buffer)
        (when-let* ((session (deathless-store-get buffer)))
          (when (deathless-store--apply-event session event)
            (deathless-store--sync session)
            (deathless-store--notify buffer))))
    (error (message "deathless: %s" (error-message-string err)))))

;;;; Tracking

(defun deathless-store-track (&optional buffer)
  "Start tracking agent-shell BUFFER (default: the current buffer).
Return its session.  Tracking a buffer twice is harmless."
  (let ((buffer (or buffer (current-buffer))))
    (or (deathless-store-get buffer)
        (when (deathless-store--state buffer)
          (let ((session (deathless-session--create
                          :buffer buffer
                          :created (cons (float-time)
                                         (cl-incf deathless-store--counter)))))
            (deathless-store--sync session)
            ;; Joining a shell mid-turn: the real start time is lost.
            (when (deathless-store--busy-p buffer)
              (setf (deathless-session-turn-start session) (float-time)))
            (setf (deathless-session-subscription session)
                  (agent-shell-subscribe-to
                   :shell-buffer buffer
                   :on-event (lambda (event)
                               (deathless-store--on-event buffer event))))
            (with-current-buffer buffer
              (add-hook 'kill-buffer-hook #'deathless-store--on-kill nil t))
            (puthash buffer session deathless-store--sessions)
            (deathless-store--notify nil)
            session)))))

(defun deathless-store-untrack (buffer)
  "Stop tracking BUFFER and forget its session."
  (when-let* ((session (deathless-store-get buffer)))
    (remhash buffer deathless-store--sessions)
    (when (and (buffer-live-p buffer) (deathless-session-subscription session))
      (with-current-buffer buffer
        (ignore-errors
          (agent-shell-unsubscribe
           :subscription (deathless-session-subscription session)))
        (remove-hook 'kill-buffer-hook #'deathless-store--on-kill t)))
    (deathless-store--notify nil)))

(defun deathless-store--on-kill ()
  "Forget the session of the buffer being killed."
  (deathless-store-untrack (current-buffer)))

(defun deathless-store-scan ()
  "Track every existing agent-shell buffer and drop dead entries."
  (dolist (buffer (hash-table-keys deathless-store--sessions))
    (unless (buffer-live-p buffer)
      (remhash buffer deathless-store--sessions)))
  (when (fboundp 'agent-shell-buffers)
    (mapc #'deathless-store-track (agent-shell-buffers))))

(defun deathless-store-refresh ()
  "Re-read every tracked session from its shell and notify listeners."
  (deathless-store-scan)
  (maphash (lambda (_buffer session) (deathless-store--sync session))
           deathless-store--sessions)
  (deathless-store--notify nil))

(defun deathless-store--on-window-change (_frame)
  "Mark sessions whose buffer is now on screen as seen."
  (maphash (lambda (buffer session)
             (when (and (deathless-session-unseen session)
                        (get-buffer-window buffer 'visible))
               (setf (deathless-session-unseen session) nil)
               (deathless-store--notify buffer)))
           deathless-store--sessions))

;;;###autoload
(define-minor-mode deathless-tracking-mode
  "Track agent-shell sessions for the deathless dashboard.
While on, every new agent-shell buffer is tracked as it starts."
  :global t
  :group 'deathless
  (if deathless-tracking-mode
      (progn
        (add-hook 'agent-shell-mode-hook #'deathless-store-track)
        (add-hook 'window-buffer-change-functions
                  #'deathless-store--on-window-change)
        (deathless-store-scan))
    (remove-hook 'agent-shell-mode-hook #'deathless-store-track)
    (remove-hook 'window-buffer-change-functions
                 #'deathless-store--on-window-change)
    (mapc #'deathless-store-untrack (hash-table-keys deathless-store--sessions))))

;;;; Actions on a shell

(defun deathless-store-respond (buffer tool-call-id option-id)
  "Answer BUFFER's permission request TOOL-CALL-ID with OPTION-ID."
  (let* ((state (or (deathless-store--state buffer)
                    (user-error "Shell is gone")))
         (request-id (map-nested-elt state (list :tool-calls tool-call-id
                                                 :permission-request-id))))
    (unless request-id
      (user-error "That permission request is no longer pending"))
    (with-current-buffer buffer
      (agent-shell--send-permission-response
       :client (map-elt state :client)
       :request-id request-id
       :option-id option-id
       :state state
       :tool-call-id tool-call-id))))

(provide 'deathless-store)
;;; deathless-store.el ends here
