;;; deathless.el --- Dashboard for agent-shell sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; Maintainer: Chaz Straney <chaz.straney@gmail.com>
;; URL: https://github.com/chazu/deathless.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.76.1") (vui "1.4.0"))
;; Keywords: tools, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; deathless is a live dashboard for every `agent-shell' session you
;; have open.  Each session is a card: its status, what it is doing
;; right now, and buttons for what you can do about it.  A permission
;; request shows up on the card with its options as buttons, so you can
;; answer it without visiting the shell.
;;
;; The dashboard updates from agent-shell's own events instead of
;; polling, so a card changes the moment its agent does, and only that
;; card is redrawn.
;;
;;   M-x deathless
;;
;; Keys on a card: RET open, a allow, A always allow, r reject,
;; i interrupt, k kill, R restart.  Anywhere: n/p next/previous card,
;; N next card waiting on you, c new agent, v compact/full, g refresh,
;; q quit, ? help.  Every button is clickable.
;;
;; Cards are compact by default: one line each, opening up only for a
;; pending permission or a failure.  See `deathless-compact'.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)
(require 'vui)
(require 'deathless-store)

(declare-function agent-shell-new-shell "agent-shell")
(declare-function agent-shell-interrupt "agent-shell")
(declare-function agent-shell-restart "agent-shell")
(declare-function agent-shell-set-session-model "agent-shell")
(declare-function agent-shell-set-session-mode "agent-shell")
(declare-function agent-shell-view-traffic "agent-shell")
(declare-function agent-shell-jump-to-latest-permission-button-row "agent-shell")

;;;; Customization

(defgroup deathless nil
  "Dashboard for agent-shell sessions."
  :group 'tools
  :prefix "deathless-")

(defcustom deathless-buffer-name "*deathless*"
  "Name of the dashboard buffer."
  :type 'string)

(defcustom deathless-display-buffer-action
  '((display-buffer-reuse-window display-buffer-in-side-window)
    (side . right)
    (window-width . 0.38)
    (preserve-size . (t . nil)))
  "Display action used by \\[deathless] to show the dashboard.
See `display-buffer' for the format."
  :type '(cons (repeat :tag "Functions" function) (alist :tag "Alist")))

(defcustom deathless-open-action #'pop-to-buffer
  "Function called with a shell buffer to open it from the dashboard."
  :type 'function)

(defcustom deathless-max-width 100
  "Widest the cards may grow, in columns."
  :type 'natnum)

(defcustom deathless-order 'stable
  "How cards are ordered.
`stable' keeps creation order, so a card never moves under you.
`attention' puts sessions waiting on you first, then working ones."
  :type '(choice (const :tag "Creation order" stable)
                 (const :tag "Needs attention first" attention)))

(defcustom deathless-compact t
  "Whether cards are drawn on one line each.
A compact card shows only its status, title, current tool call and
clock, and opens up only when it needs you: a pending permission
gets its buttons, a failure its error.  nil draws full cards, with
details and buttons.  `auto' goes compact only when the full cards
would not fit the window's height.  \\<deathless-mode-map>\
\\[deathless-toggle-compact] toggles it in the dashboard."
  :type '(choice (const :tag "Full cards" nil)
                 (const :tag "Compact" t)
                 (const :tag "Compact when full cards do not fit" auto)))

(defcustom deathless-confirm-kill t
  "When non-nil, ask before killing a session."
  :type 'boolean)

;;;; Faces

(defface deathless-heading
  '((t :inherit bold :height 1.25))
  "Face for the dashboard title.")

(defface deathless-title
  '((t :inherit bold))
  "Face for a session's title.")

(defface deathless-meta
  '((t :inherit shadow))
  "Face for secondary details on a card.")

(defface deathless-rule
  '((t :inherit shadow))
  "Face for horizontal rules.")

(defface deathless-activity
  '((t :inherit (shadow italic)))
  "Face for a working session's current activity.")

(defface deathless-status-blocked
  '((t :inherit warning))
  "Colour of sessions waiting on a permission.")

(defface deathless-status-working
  '((((class color) (background dark)) :foreground "#7aa2f7")
    (((class color) (background light)) :foreground "#2a5bd7")
    (t :inherit font-lock-function-name-face))
  "Colour of sessions running a turn.")

(defface deathless-status-done
  '((t :inherit success))
  "Colour of sessions whose finished turn you have not seen.")

(defface deathless-status-ready
  '((t :inherit success))
  "Colour of idle sessions.")

(defface deathless-status-starting
  '((t :inherit shadow))
  "Colour of sessions still starting.")

(defface deathless-status-failed
  '((t :inherit error))
  "Colour of sessions whose last turn failed.")

(defface deathless-status-stopped
  '((t :inherit shadow))
  "Colour of sessions whose last turn was cut short.")

(defface deathless-status-exited
  '((t :inherit shadow))
  "Colour of sessions whose agent process is gone.")

(defface deathless-button
  '((t :inherit custom-button))
  "Face for card buttons.")

(defface deathless-button-allow
  '((((class color) (min-colors 88) (background dark))
     :inherit deathless-button :foreground "#1a1b26" :background "#9ece6a")
    (((class color) (min-colors 88) (background light))
     :inherit deathless-button :foreground "white" :background "#2e7d32")
    (t :inherit deathless-button))
  "Face for buttons that allow a tool call.")

(defface deathless-button-reject
  '((((class color) (min-colors 88) (background dark))
     :inherit deathless-button :foreground "#1a1b26" :background "#f7768e")
    (((class color) (min-colors 88) (background light))
     :inherit deathless-button :foreground "white" :background "#c62828")
    (t :inherit deathless-button))
  "Face for buttons that reject a tool call.")

;;;; Formatting helpers

(defconst deathless--spinner ["◐" "◓" "◑" "◒"]
  "Frames of the working indicator.")

(defconst deathless--statuses
  '((blocked  "◆" "NEEDS YOU" deathless-status-blocked)
    (working  nil "WORKING"   deathless-status-working)
    (done     "●" "DONE"      deathless-status-done)
    (failed   "✗" "FAILED"    deathless-status-failed)
    (starting "○" "STARTING"  deathless-status-starting)
    (stopped  "■" "STOPPED"   deathless-status-stopped)
    (ready    "○" "READY"     deathless-status-ready)
    (exited   "✕" "EXITED"    deathless-status-exited))
  "Status symbol to (GLYPH LABEL FACE).  A nil GLYPH is the spinner.")

(defconst deathless--pill-width 13
  "Columns every status pill is padded to, so titles line up.")

(defun deathless--status-face (status)
  "Return the face that colours STATUS."
  (nth 2 (alist-get status deathless--statuses)))

(defun deathless--glyph (status)
  "Return the glyph for STATUS, animating the working spinner."
  (or (nth 0 (alist-get status deathless--statuses))
      (aref deathless--spinner
            (mod (truncate (float-time)) (length deathless--spinner)))))

(defun deathless--pill-face (status)
  "Return a face for a filled pill in STATUS's colour."
  (let* ((face (deathless--status-face status))
         (colour (face-foreground face nil t)))
    (if (and colour (display-graphic-p))
        `(:background ,colour
          :foreground ,(or (face-background 'default nil t) "black")
          :weight bold)
      `(:inherit ,face :weight bold :inverse-video t))))

(defun deathless--pill (status)
  "Return the padded status pill string for STATUS."
  (let ((label (format " %s %s " (deathless--glyph status)
                       (nth 1 (alist-get status deathless--statuses)))))
    (propertize (string-pad label deathless--pill-width)
                'face (deathless--pill-face status))))

(defun deathless--duration (seconds)
  "Format SECONDS as a short duration such as 4m12s."
  (let ((s (max 0 (truncate seconds))))
    (cond ((< s 60) (format "%ds" s))
          ((< s 3600) (format "%dm%02ds" (/ s 60) (% s 60)))
          ((< s 86400) (format "%dh%02dm" (/ s 3600) (/ (% s 3600) 60)))
          (t (format "%dd" (/ s 86400))))))

(defun deathless--ago (time)
  "Format TIME, a `float-time', as a coarse age such as 12m ago."
  (let ((s (truncate (- (float-time) time))))
    (cond ((< s 45) "just now")
          ((< s 3600) (format "%dm ago" (max 1 (/ s 60))))
          ((< s 86400) (format "%dh ago" (/ s 3600)))
          (t (format "%dd ago" (/ s 86400))))))

(defun deathless--tokens (n)
  "Format token count N compactly, such as 45.2k."
  (cond ((< n 1000) (format "%d" n))
        ((< n 1000000) (format "%.1fk" (/ n 1000.0)))
        (t (format "%.2fM" (/ n 1000000.0)))))

(defun deathless--usage-text (usage)
  "Return a short summary of agent-shell USAGE, or nil."
  (let ((used (or (map-elt usage :context-used) 0))
        (size (or (map-elt usage :context-size) 0))
        (total (or (map-elt usage :total-tokens) 0))
        (cost (or (map-elt usage :cost-amount) 0)))
    (string-join
     (delq nil
           (list (cond ((> size 0)
                        (format "ctx %s/%s (%d%%)" (deathless--tokens used)
                                (deathless--tokens size)
                                (round (* 100.0 (/ (float used) size)))))
                       ((> total 0) (format "%s tokens" (deathless--tokens total))))
                 (when (> cost 0) (format "$%.2f" cost))))
     " · ")))

(defun deathless--clock (session)
  "Return the time column for SESSION."
  (let ((start (deathless-session-turn-start session))
        (end (deathless-session-finished-at session)))
    (cond (start (deathless--duration (- (float-time) start)))
          (end (deathless--ago end))
          (t ""))))

(defun deathless--width ()
  "Return the width cards are laid out to in the current buffer."
  (let ((window (get-buffer-window (current-buffer) t)))
    (max 40 (min deathless-max-width
                 (- (if window (window-body-width window) 80) 2)))))

(defun deathless--fit (string width)
  "Truncate STRING to WIDTH columns, with an ellipsis when cut."
  (truncate-string-to-width (or string "") (max 0 width) nil nil "…"))

(defun deathless--spread (left right width)
  "Return LEFT and RIGHT joined by enough spaces to fill WIDTH."
  (concat left
          (make-string (max 1 (- width (string-width left) (string-width right))) ?\s)
          right))

;;;; Ordering

(defconst deathless--attention-rank
  '((blocked . 0) (failed . 1) (done . 2) (working . 3) (starting . 4)
    (stopped . 5) (ready . 6) (exited . 7))
  "Sort rank of each status under the `attention' order.")

(defun deathless--ordered-sessions ()
  "Return the sessions in the order `deathless-order' asks for."
  (let ((sessions (deathless-store-sessions)))
    (if (eq deathless-order 'attention)
        (seq-sort-by (lambda (s)
                       (alist-get (deathless-session-status s)
                                  deathless--attention-rank))
                     #'< sessions)
      sessions)))

;;;; Card actions
;;
;; Each action takes the shell buffer, so buttons and keys share them.

(defun deathless--check-live (buffer)
  "Signal a `user-error' unless BUFFER is live."
  (unless (buffer-live-p buffer)
    (user-error "That session is gone")))

(defun deathless--open (buffer)
  "Show shell BUFFER using `deathless-open-action'."
  (deathless--check-live buffer)
  (when-let* ((session (deathless-store-get buffer)))
    (setf (deathless-session-unseen session) nil))
  (funcall deathless-open-action buffer))

(defun deathless--show-permission (buffer)
  "Open BUFFER at its latest permission prompt."
  (deathless--open buffer)
  (with-current-buffer buffer
    (when (fboundp 'agent-shell-jump-to-latest-permission-button-row)
      (agent-shell-jump-to-latest-permission-button-row))))

(defun deathless--interrupt (buffer)
  "Interrupt the turn running in BUFFER."
  (deathless--check-live buffer)
  (with-current-buffer buffer (agent-shell-interrupt t)))

(defun deathless--kill (buffer)
  "Kill shell BUFFER, asking first when `deathless-confirm-kill'."
  (deathless--check-live buffer)
  (when (or (not deathless-confirm-kill)
            (y-or-n-p (format "Kill %s? " (buffer-name buffer))))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buffer))))

(defun deathless--restart (buffer)
  "Restart the agent in BUFFER with a fresh conversation."
  (deathless--check-live buffer)
  (when (y-or-n-p (format "Restart %s?  Its conversation will be cleared. "
                          (buffer-name buffer)))
    (with-current-buffer buffer (agent-shell-restart))))

(defun deathless--action-face (kind)
  "Return the button face for permission action KIND."
  (cond ((string-prefix-p "allow" (or kind "")) 'deathless-button-allow)
        ((string-prefix-p "reject" (or kind "")) 'deathless-button-reject)
        (t 'deathless-button)))

(defun deathless--permission-action (session kind)
  "Return SESSION's oldest pending (PERMISSION . ACTION) of KIND, or nil.
KIND is an ACP permission kind such as \"allow_once\"."
  (seq-some (lambda (permission)
              (when-let* ((action (seq-find (lambda (a) (equal (map-elt a :kind) kind))
                                            (plist-get permission :actions))))
                (cons permission action)))
            (deathless-session-permissions session)))

(defun deathless--answer (session kinds)
  "Answer SESSION's oldest permission with the first of KINDS it offers."
  (let ((match (seq-some (lambda (kind) (deathless--permission-action session kind))
                         kinds)))
    (unless match
      (user-error (if (deathless-session-permissions session)
                      "No such option for this request"
                    "Nothing is waiting for permission here")))
    (deathless-store-respond (deathless-session-buffer session)
                             (plist-get (car match) :tool-call-id)
                             (map-elt (cdr match) :option-id))))

;;;; Rendering

(defun deathless--button (label action &optional face help)
  "Return a button showing LABEL that calls ACTION when pushed.
FACE defaults to `deathless-button'; HELP is its tooltip."
  (vui-button (format " %s " label)
    :on-click action
    :no-decoration t
    :face (or face 'deathless-button)
    :help-echo help))

(defun deathless--card-map (buffer)
  "Return the keymap active over BUFFER's card."
  (let ((map (make-sparse-keymap))
        (session (lambda () (or (deathless-store-get buffer)
                                (user-error "That session is gone")))))
    (keymap-set map "RET" (lambda () (interactive) (deathless--open buffer)))
    (keymap-set map "o" (lambda () (interactive) (deathless--open buffer)))
    (keymap-set map "a" (lambda () (interactive)
                          (deathless--answer (funcall session) '("allow_once"))))
    (keymap-set map "A" (lambda () (interactive)
                          (deathless--answer (funcall session) '("allow_always"))))
    (keymap-set map "r" (lambda () (interactive)
                          (deathless--answer (funcall session)
                                             '("reject_once" "reject_always"))))
    (keymap-set map "s" (lambda () (interactive) (deathless--show-permission buffer)))
    (keymap-set map "i" (lambda () (interactive) (deathless--interrupt buffer)))
    (keymap-set map "k" (lambda () (interactive) (deathless--kill buffer)))
    (keymap-set map "R" (lambda () (interactive) (deathless--restart buffer)))
    (keymap-set map "m" (lambda () (interactive)
                          (deathless--check-live buffer)
                          (with-current-buffer buffer (agent-shell-set-session-mode))))
    (keymap-set map "M" (lambda () (interactive)
                          (deathless--check-live buffer)
                          (with-current-buffer buffer (agent-shell-set-session-model))))
    (keymap-set map "t" (lambda () (interactive)
                          (deathless--check-live buffer)
                          (with-current-buffer buffer (agent-shell-view-traffic))))
    map))

(defun deathless--render-header-line (session status width)
  "Return the first line of SESSION's card, in STATUS, WIDTH wide."
  (let* ((buffer (deathless-session-buffer session))
         (pill (deathless--pill status))
         (right (concat (deathless-session-agent session) "  "
                        (deathless--clock session)))
         (room (- width (string-width pill) 2 (string-width right)))
         (title (deathless--fit (or (deathless-session-title session)
                                    (buffer-name buffer))
                                room)))
    (vui-hstack
     :spacing 0
     ;; The pill carries the card's buffer, which is how commands that
     ;; act on "the card at point" find it.
     (vui-text pill 'deathless-buffer buffer)
     (vui-text " ")
     (vui-button title
       :on-click (lambda () (deathless--open buffer))
       :no-decoration t
       :face 'deathless-title
       :help-echo "mouse-1: open this session"
       :key (cons 'title buffer))
     (vui-text (make-string (max 1 (- width (string-width pill) 1
                                      (string-width title) (string-width right)))
                            ?\s))
     (vui-text right :face 'deathless-meta))))

(defun deathless--render-meta-line (session width)
  "Return SESSION's details line, at most WIDTH wide."
  (let ((parts (delq nil (list (deathless-session-cwd session)
                               (deathless-session-model session)
                               (deathless-session-mode session)
                               (deathless--usage-text (deathless-session-usage session))))))
    (vui-text (deathless--fit (string-join (seq-remove #'string-empty-p parts) " · ")
                              width)
      :face 'deathless-meta)))

(defun deathless--render-activity (session status width)
  "Return what SESSION in STATUS is doing or why it stopped, or nil."
  (let ((tool (deathless-session-last-tool session)))
    (pcase status
      ('working
       (vui-text (deathless--fit
                  (if tool
                      (format "↳ %s" (plist-get tool :title))
                    "↳ thinking…")
                  width)
         :face 'deathless-activity))
      ('failed
       (vui-text (deathless--fit (format "✗ %s" (deathless-session-error session)) width)
         :face 'deathless-status-failed))
      ('stopped
       (vui-text (format "■ stopped: %s"
                         (string-replace "_" " " (deathless-session-stop-reason session)))
         :face 'deathless-meta)))))

(defun deathless--render-permission (session permission width)
  "Return the block for SESSION's pending PERMISSION, WIDTH wide."
  (let* ((buffer (deathless-session-buffer session))
         (bar (propertize "▌ " 'face 'deathless-status-blocked))
         (kind (plist-get permission :kind))
         (heading (deathless--fit (concat (if kind (format "%s: " kind) "")
                                          (or (plist-get permission :title) "Tool call"))
                                  (- width 4))))
    (vui-vstack
     (vui-hstack :spacing 0
                 (vui-text bar)
                 (vui-text (concat "⚠ " heading) :face 'deathless-status-blocked))
     (vui-hstack
      :spacing 0
      (vui-text bar)
      (apply #'vui-hstack
             :spacing 1
             (append
              (mapcar (lambda (action)
                        (let ((tool-call-id (plist-get permission :tool-call-id))
                              (option-id (map-elt action :option-id)))
                          (deathless--button
                           (map-elt action :option)
                           (lambda () (deathless-store-respond buffer tool-call-id option-id))
                           (deathless--action-face (map-elt action :kind)))))
                      (plist-get permission :actions))
              (list (deathless--button "Show" (lambda () (deathless--show-permission buffer))
                                       nil "Open the shell at this request"))))))))

(defun deathless--render-actions (session status)
  "Return the action buttons for SESSION in STATUS."
  (let ((buffer (deathless-session-buffer session)))
    (apply #'vui-hstack
           :spacing 1
           (delq nil
                 (list
                  (deathless--button "Open" (lambda () (deathless--open buffer)))
                  (when (memq status '(working blocked))
                    (deathless--button "Interrupt" (lambda () (deathless--interrupt buffer))))
                  (when (memq status '(exited failed stopped ready done))
                    (deathless--button "Restart" (lambda () (deathless--restart buffer))))
                  (deathless--button "Kill" (lambda () (deathless--kill buffer))))))))

(defun deathless--render-card (session width)
  "Return the card for SESSION, WIDTH wide."
  (let* ((buffer (deathless-session-buffer session))
         (status (deathless-session-status session)))
    (vui-region
     :keymap (deathless--card-map buffer)
     :key buffer
     (vui-vstack
      :indent 1
      (deathless--render-header-line session status width)
      (vui-vstack
       :indent (1+ deathless--pill-width)
       (deathless--render-meta-line session (- width deathless--pill-width 1))
       (deathless--render-activity session status (- width deathless--pill-width 1))
       (mapcar (lambda (permission)
                 (deathless--render-permission session permission
                                               (- width deathless--pill-width 1)))
               (deathless-session-permissions session))
       (deathless--render-actions session status))))))

(defun deathless--render-compact-line (session status width)
  "Return SESSION's one-line card in STATUS, WIDTH wide."
  (let* ((buffer (deathless-session-buffer session))
         (pill (deathless--pill status))
         (right (deathless--clock session))
         (room (- width (string-width pill) 2 (string-width right)))
         (title (deathless--fit (or (deathless-session-title session)
                                    (buffer-name buffer))
                                (if (eq status 'working) (min room (max 20 (/ room 2))) room)))
         (tool (plist-get (deathless-session-last-tool session) :title))
         (activity (if (and (eq status 'working) tool)
                       (deathless--fit (concat "  ↳ " tool)
                                       (- room (string-width title)))
                     "")))
    (vui-hstack
     :spacing 0
     (vui-text pill 'deathless-buffer buffer)
     (vui-text " ")
     (vui-button title
       :on-click (lambda () (deathless--open buffer))
       :no-decoration t
       :face 'deathless-title
       :help-echo "mouse-1: open this session"
       :key (cons 'title buffer))
     (vui-text activity :face 'deathless-activity)
     (vui-text (make-string (max 1 (- width (string-width pill) 1 (string-width title)
                                      (string-width activity) (string-width right)))
                            ?\s))
     (vui-text right :face 'deathless-meta))))

(defun deathless--render-compact-card (session width)
  "Return SESSION's compact card, WIDTH wide.
The card is one line unless SESSION is waiting on a permission or failed."
  (let* ((buffer (deathless-session-buffer session))
         (status (deathless-session-status session))
         (inner (- width deathless--pill-width 1)))
    (vui-region
     :keymap (deathless--card-map buffer)
     :key buffer
     (vui-vstack
      :indent 1
      (deathless--render-compact-line session status width)
      (vui-vstack
       :indent (1+ deathless--pill-width)
       (when (eq status 'failed)
         (deathless--render-activity session status inner))
       (mapcar (lambda (permission)
                 (deathless--render-permission session permission inner))
               (deathless-session-permissions session)))))))

(defun deathless--full-height (sessions)
  "Return roughly how many lines full cards for SESSIONS take."
  (+ 6 (seq-reduce (lambda (lines s)
                     (+ lines 4 (* 2 (length (deathless-session-permissions s)))))
                   sessions 0)))

(defun deathless--compact-p (sessions)
  "Return non-nil when SESSIONS should be drawn as compact cards."
  (pcase deathless-compact
    ('auto (let ((window (get-buffer-window (current-buffer) t)))
             (and window (> (deathless--full-height sessions)
                            (window-body-height window)))))
    (value value)))

(defun deathless--summary (sessions)
  "Return the header's status counts for SESSIONS as a string."
  (let ((counts (seq-group-by #'deathless-session-status sessions)))
    (string-join
     (delq nil
           (mapcar (lambda (entry)
                     (pcase-let ((`(,statuses ,label ,face) entry))
                       (let ((n (seq-reduce (lambda (sum status)
                                              (+ sum (length (alist-get status counts))))
                                            statuses 0)))
                         (when (> n 0)
                           (propertize (format "%d %s" n label) 'face face)))))
                   '(((blocked) "need you" deathless-status-blocked)
                     ((failed) "failed" deathless-status-failed)
                     ((done) "done" deathless-status-done)
                     ((working) "working" deathless-status-working)
                     ((ready stopped starting exited) "idle" deathless-meta))))
     (propertize " · " 'face 'deathless-meta))))

(defun deathless--render-empty ()
  "Return the view shown when no sessions exist."
  (vui-vstack
   :indent 1
   (vui-text "No agent sessions yet." :face 'deathless-meta)
   (vui-newline)
   (deathless--button "+ New agent" #'deathless-new)))

(defun deathless--render-root ()
  "Return the whole dashboard."
  (let* ((width (deathless--width))
         (sessions (deathless--ordered-sessions))
         (compact (deathless--compact-p sessions))
         (rule (propertize (make-string (+ 1 width) ?─) 'face 'deathless-rule)))
    (vui-vstack
     (vui-text (deathless--spread (propertize " deathless" 'face 'deathless-heading)
                                  (deathless--summary sessions)
                                  (1+ width)))
     (vui-text rule)
     (unless compact (vui-newline))
     (cond ((null sessions) (deathless--render-empty))
           (compact
            (apply #'vui-vstack
                   (mapcar (lambda (session) (deathless--render-compact-card session width))
                           sessions)))
           (t
            (apply #'vui-vstack
                   :spacing 1
                   (mapcar (lambda (session) (deathless--render-card session width))
                           sessions))))
     ;; The key hints cost three lines a compact view cannot spare; ? has them.
     (unless compact
       (vui-vstack
        (vui-newline)
        (vui-text rule)
        (vui-text (deathless--fit
                   (concat " " (substitute-command-keys
                                "\\<deathless-mode-map>RET open · a/r allow/reject · \
i interrupt · \\[deathless-next-attention] next waiting · \\[deathless-new] new · \
\\[deathless-toggle-compact] compact · \\[deathless-help] help"))
                   (1+ width))
          :face 'deathless-meta))))))

(defun deathless--ticking-p ()
  "Return non-nil when some card shows a clock that runs."
  (seq-some (lambda (s) (memq (deathless-session-status s) '(working blocked starting)))
            (deathless-store-sessions)))

(vui-defcomponent deathless-view ()
  "The deathless dashboard."
  :state ((tick 0))
  :render
  (progn
    (vui-use-effect ()
      (let* ((bump (vui-with-async-context (vui-set-state :tick #'1+)))
             (listener (lambda (_buffer) (funcall bump)))
             (beats 0)
             ;; Running clocks and the spinner change every second; ages
             ;; ("12m ago") only need a refresh now and then.
             (timer (run-with-timer
                     1 1 (lambda ()
                           (when (or (deathless--ticking-p)
                                     (zerop (% (cl-incf beats) 30)))
                             (funcall bump))))))
        (add-hook 'deathless-store-change-functions listener)
        (lambda ()
          (cancel-timer timer)
          (remove-hook 'deathless-store-change-functions listener))))
    (ignore tick)
    (deathless--render-root)))

;;;; Commands

(defun deathless--buffer-at-point ()
  "Return the shell buffer of the card at point, or nil."
  (let ((pos (point)))
    (or (get-text-property pos 'deathless-buffer)
        (when-let* ((start (previous-single-property-change
                            (min (1+ pos) (point-max)) 'deathless-buffer)))
          (get-text-property (max (point-min) (1- start)) 'deathless-buffer)))))

(defun deathless--card-starts ()
  "Return the buffer positions where cards begin, in order."
  (let ((pos (point-min)) starts)
    (while (setq pos (next-single-property-change pos 'deathless-buffer))
      (when (get-text-property pos 'deathless-buffer)
        (push pos starts)))
    (nreverse starts)))

(defun deathless-next (&optional n)
  "Move to the start of the Nth next card."
  (interactive "p")
  (let* ((n (or n 1))
         (starts (deathless--card-starts))
         (targets (if (> n 0)
                      (seq-filter (lambda (p) (> p (point))) starts)
                    (reverse (seq-filter (lambda (p) (< p (point))) starts))))
         (target (nth (1- (abs n)) targets)))
    (if target
        (progn (goto-char target)
               (when-let* ((title (next-single-property-change
                                   target 'deathless-buffer)))
                 (goto-char (1+ title))))
      (message "No more cards"))))

(defun deathless-previous (&optional n)
  "Move to the start of the Nth previous card."
  (interactive "p")
  (deathless-next (- (or n 1))))

(defun deathless-next-attention ()
  "Move to the next card that is waiting on you, wrapping around."
  (interactive)
  (let* ((starts (deathless--card-starts))
         (waiting (seq-filter
                   (lambda (pos)
                     (when-let* ((session (deathless-store-get
                                           (get-text-property pos 'deathless-buffer))))
                       (deathless-session-needs-attention-p session)))
                   starts))
         (target (or (seq-find (lambda (p) (> p (point))) waiting) (car waiting))))
    (if target
        (goto-char (1+ (or (next-single-property-change target 'deathless-buffer)
                           target)))
      (message "Nothing needs you"))))

(defun deathless-new ()
  "Start a new agent-shell session."
  (interactive)
  (agent-shell-new-shell))

(defun deathless-refresh ()
  "Re-read every session from its shell."
  (interactive)
  (deathless-store-refresh))

(defun deathless-toggle-compact ()
  "Switch this dashboard between compact and full cards.
The choice holds for this buffer; `deathless-compact' sets the default."
  (interactive)
  (setq-local deathless-compact
              (not (deathless--compact-p (deathless-store-sessions))))
  (when-let* ((root (vui-get-instance (current-buffer))))
    (vui-rerender root))
  (message "deathless: %s cards" (if deathless-compact "compact" "full")))

(defun deathless-help ()
  "Describe the dashboard's keys."
  (interactive)
  (describe-function 'deathless-mode))

(defvar-keymap deathless-mode-map
  :doc "Keymap for `deathless-mode'.  Cards add their own keys on top."
  "n" #'deathless-next
  "p" #'deathless-previous
  "N" #'deathless-next-attention
  "c" #'deathless-new
  "g" #'deathless-refresh
  "v" #'deathless-toggle-compact
  "q" #'quit-window
  "?" #'deathless-help)

(define-derived-mode deathless-mode vui-mode "Deathless"
  "Dashboard of agent-shell sessions.

Each card is one session.  With point on a card:

  RET, o   open the session
  a        allow the pending tool call once
  A        always allow it
  r        reject it
  s        show the request in the shell
  i        interrupt the running turn
  k        kill the session
  R        restart with a fresh conversation
  m, M     set session mode, model
  t        view ACP traffic

Anywhere:

\\{deathless-mode-map}"
  :group 'deathless
  (setq-local truncate-lines t)
  (setq-local cursor-in-non-selected-windows nil))

;;;###autoload
(defun deathless ()
  "Show the dashboard of agent-shell sessions."
  (interactive)
  (require 'agent-shell)
  (unless deathless-tracking-mode
    (deathless-tracking-mode 1))
  (let ((buffer (get-buffer-create deathless-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'deathless-mode)
        (deathless-mode)))
    ;; Show the buffer before the first render so cards are laid out to
    ;; the window they will actually appear in.
    (let ((window (display-buffer buffer deathless-display-buffer-action)))
      (when window (select-window window)))
    (with-current-buffer buffer
      (if-let* ((root (vui-get-instance buffer)))
          (vui-rerender root)
        (vui-render (vui-component 'deathless-view) buffer)
        (vui-rerender-on-resize buffer)))
    buffer))

(provide 'deathless)
;;; deathless.el ends here
