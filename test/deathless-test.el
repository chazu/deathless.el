;;; deathless-test.el --- Tests for deathless -*- lexical-binding: t; -*-

;;; Commentary:

;; Runs without agent-shell: a fake shell is a buffer with a
;; buffer-local `agent-shell--state' alist and a live pipe process.

;;; Code:

(require 'ert)
(require 'deathless)

(defvar-local agent-shell--state nil)
(defvar agent-shell-cwd-function nil)

(defun deathless-test--state (&rest overrides)
  "Return a fake agent-shell state alist, with OVERRIDES applied.
OVERRIDES is a plist of top-level keys."
  (let ((state (list (cons :initialized t)
                     (cons :client nil)
                     (cons :agent-config (list (cons :mode-line-name "Claude")))
                     (cons :session (list (cons :id "s1")
                                          (cons :title "Refactor auth middleware")
                                          (cons :model-id "opus")
                                          (cons :models (list (list (cons :model-id "opus")
                                                                    (cons :name "Opus 5.5"))))
                                          (cons :mode-id nil)
                                          (cons :modes nil)))
                     (cons :tool-calls nil)
                     (cons :usage (list (cons :context-used 45200)
                                        (cons :context-size 200000)
                                        (cons :total-tokens 50000)
                                        (cons :cost-amount 0.42))))))
    (cl-loop for (key value) on overrides by #'cddr
             do (setf (alist-get key state) value))
    state))

(defmacro deathless-test--with-shell (binding &rest body)
  "Run BODY with (VAR STATE) BINDING bound to a tracked fake shell buffer."
  (declare (indent 1))
  (let ((var (car binding)))
    `(let* ((deathless-store--sessions (make-hash-table :test #'eq))
            (deathless-store-change-functions nil)
            (,var (generate-new-buffer " *fake-shell*")))
       (unwind-protect
           (progn
             (with-current-buffer ,var
               (setq agent-shell--state ,(cadr binding))
               (make-pipe-process :name "fake-shell" :buffer ,var :noquery t))
             (puthash ,var (deathless-store--sync
                            (deathless-session--create :buffer ,var :created (cons 0 0)))
                      deathless-store--sessions)
             ,@body)
         (let ((kill-buffer-query-functions nil))
           (kill-buffer ,var))))))

(defun deathless-test--emit (buffer event &rest data)
  "Feed EVENT with DATA (a plist turned alist) to BUFFER's session."
  (deathless-store--on-event
   buffer (list (cons :event event)
                (cons :data (cl-loop for (k v) on data by #'cddr collect (cons k v))))))

(defun deathless-test--status (buffer)
  "Return the status of BUFFER's session."
  (deathless-session-status (deathless-store-get buffer)))

(ert-deftest deathless-test-sync-reads-state ()
  (deathless-test--with-shell (shell (deathless-test--state))
    (let ((session (deathless-store-get shell)))
      (should (equal (deathless-session-agent session) "Claude"))
      (should (equal (deathless-session-title session) "Refactor auth middleware"))
      (should (equal (deathless-session-model session) "Opus 5.5"))
      (should (deathless-session-alive session))
      (should (eq (deathless-test--status shell) 'ready)))))

(ert-deftest deathless-test-turn-lifecycle ()
  (deathless-test--with-shell (shell (deathless-test--state))
    (deathless-test--emit shell 'input-submitted :prompt "go")
    (should (eq (deathless-test--status shell) 'working))
    (deathless-test--emit shell 'tool-call-update
                          :tool-call-id "t1"
                          :tool-call '((:title . "Run npm test") (:kind . "execute")))
    (should (equal (plist-get (deathless-session-last-tool (deathless-store-get shell)) :title)
                   "Run npm test"))
    (deathless-test--emit shell 'turn-complete :stop-reason "end_turn")
    ;; The fake shell is never on screen, so the finished turn is unseen.
    (should (eq (deathless-test--status shell) 'done))
    (setf (deathless-session-unseen (deathless-store-get shell)) nil)
    (should (eq (deathless-test--status shell) 'ready))))

(ert-deftest deathless-test-stop-reasons ()
  (deathless-test--with-shell (shell (deathless-test--state))
    (deathless-test--emit shell 'input-submitted)
    (deathless-test--emit shell 'turn-complete :stop-reason "cancelled")
    (should (eq (deathless-test--status shell) 'stopped))
    (deathless-test--emit shell 'input-submitted)
    (deathless-test--emit shell 'error :message "overloaded")
    (should (eq (deathless-test--status shell) 'working))
    (deathless-test--emit shell 'turn-complete :stop-reason "end_turn")
    (should (eq (deathless-test--status shell) 'failed))))

(ert-deftest deathless-test-permission-blocks ()
  (deathless-test--with-shell (shell (deathless-test--state))
    (deathless-test--emit shell 'input-submitted)
    (with-current-buffer shell
      (setf (alist-get :tool-calls agent-shell--state)
            (list (cons "t1" (list (cons :title "Edit src/auth.ts")
                                   (cons :kind "edit")
                                   (cons :permission-request-id 7)
                                   (cons :permission-actions
                                         (list '((:option . "Allow") (:kind . "allow_once")
                                                 (:option-id . "allow"))
                                               '((:option . "Reject") (:kind . "reject_once")
                                                 (:option-id . "reject")))))))))
    (deathless-test--emit shell 'permission-request :tool-call-id "t1")
    (should (eq (deathless-test--status shell) 'blocked))
    (should (deathless-session-needs-attention-p (deathless-store-get shell)))
    (let ((permission (car (deathless-session-permissions (deathless-store-get shell)))))
      (should (equal (plist-get permission :request-id) 7))
      (should (equal (plist-get permission :title) "Edit src/auth.ts")))
    (with-current-buffer shell
      (setf (alist-get :tool-calls agent-shell--state) nil))
    (deathless-test--emit shell 'permission-response :tool-call-id "t1")
    (should (eq (deathless-test--status shell) 'working))))

(ert-deftest deathless-test-dead-process-exits ()
  (deathless-test--with-shell (shell (deathless-test--state))
    (deathless-test--emit shell 'input-submitted)
    (delete-process (get-buffer-process shell))
    (deathless-test--emit shell 'tool-call-update :tool-call '((:title . "x")))
    (should (eq (deathless-test--status shell) 'exited))))

(ert-deftest deathless-test-change-hook-fires ()
  (deathless-test--with-shell (shell (deathless-test--state))
    (let (seen)
      (add-hook 'deathless-store-change-functions (lambda (b) (push b seen)))
      (deathless-test--emit shell 'input-submitted)
      (deathless-test--emit shell 'agent-message-chunk :text-chunk "hi")
      ;; Chunks are ignored; the prompt counts once.
      (should (equal seen (list shell))))))

(ert-deftest deathless-test-clean-up-untracks ()
  (deathless-test--with-shell (shell (deathless-test--state))
    (deathless-test--emit shell 'clean-up)
    (should-not (deathless-store-get shell))))

(ert-deftest deathless-test-formatting ()
  (should (equal (deathless--duration 252) "4m12s"))
  (should (equal (deathless--duration 7) "7s"))
  (should (equal (deathless--tokens 45200) "45.2k"))
  (should (equal (deathless--usage-text '((:context-used . 45200) (:context-size . 200000)
                                          (:cost-amount . 0.42)))
                 "ctx 45.2k/200.0k (23%) · $0.42")))

(ert-deftest deathless-test-short-dir ()
  (should (equal (deathless--short-dir "~/dev/x" 20) "~/dev/x"))
  (should (equal (deathless--short-dir "~/dev/birnam/birnam" 16) "…/birnam/birnam"))
  (should (equal (deathless--short-dir "~/dev/birnam/birnam" 10) "…/birnam"))
  (should (equal (deathless--short-dir "~/dev/averyverylongname" 8) "…ongname"))
  (should (equal (deathless--short-dir nil 10) "")))

(ert-deftest deathless-test-render-dir ()
  ;; The old layout, with the directory just left of the time, still works.
  (deathless-test--with-shell (shell (deathless-test--state))
    (deathless-test--emit shell 'input-submitted)
    (setf (deathless-session-cwd (deathless-store-get shell)) "~/w/proj")
    (let ((deathless-compact nil)
          (deathless-card-header-format '(:left (status title) :right (agent dir clock))))
      (should (string-match-p "WORKING +Refactor auth middleware +Claude  ~/w/proj +[0-9]+s\n"
                              (deathless-test--render-text))))
    (let ((deathless-compact t)
          (deathless-card-compact-format '(:left (status title activity) :right (dir clock))))
      (should (string-match-p "WORKING +Refactor auth middleware +~/w/proj +[0-9]+s\n?\\'"
                              (deathless-test--render-text))))))

(ert-deftest deathless-test-render ()
  (deathless-test--with-shell (shell (deathless-test--state))
    (deathless-test--emit shell 'input-submitted)
    (with-current-buffer shell
      (setf (alist-get :tool-calls agent-shell--state)
            (list (cons "t1" (list (cons :title "Edit src/auth.ts")
                                   (cons :kind "edit")
                                   (cons :permission-request-id 7)
                                   (cons :permission-actions
                                         (list '((:option . "Allow") (:kind . "allow_once")
                                                 (:option-id . "allow")))))))))
    (deathless-test--emit shell 'permission-request :tool-call-id "t1")
    (let ((view (generate-new-buffer " *deathless-test*"))
          (deathless-compact nil))
      (unwind-protect
          (with-current-buffer view
            (deathless-mode)
            (vui-render (vui-component 'deathless-view) view)
            (vui-flush-sync)
            (let ((text (buffer-string)))
              (should (string-match-p "NEEDS YOU" text))
              (should (string-match-p "Refactor auth middleware" text))
              (should (string-match-p "edit: Edit src/auth.ts" text))
              (should (string-match-p " Allow " text))
              (should (string-match-p "Opus 5.5" text)))
            ;; The card is findable from anywhere on it.
            (goto-char (point-min))
            (search-forward "Opus 5.5")
            (should (eq (deathless--buffer-at-point) shell))
            (goto-char (point-min))
            (deathless-next)
            (should (eq (deathless--buffer-at-point) shell)))
        (kill-buffer view)))))

(defun deathless-test--render-text ()
  "Render the dashboard into a scratch buffer and return its text."
  (let ((view (generate-new-buffer " *deathless-test*")))
    (unwind-protect
        (with-current-buffer view
          (deathless-mode)
          (vui-render (vui-component 'deathless-view) view)
          (vui-flush-sync)
          (buffer-substring-no-properties (point-min) (point-max)))
      (kill-buffer view))))

(ert-deftest deathless-test-compact ()
  (deathless-test--with-shell (shell (deathless-test--state))
    (deathless-test--emit shell 'input-submitted)
    (deathless-test--emit shell 'tool-call-update
                          :tool-call '((:title . "Run npm test")))
    (let* ((deathless-compact t)
           (text (deathless-test--render-text))
           (lines (split-string text "\n" t)))
      ;; One line for the working card: no header, meta line, buttons or
      ;; footer.
      (should (= (length lines) 1))
      (should (string-match-p "WORKING +[^ ]+ +Refactor auth middleware +↳ Run npm test" text))
      (should-not (string-match-p "Opus 5.5\\| Open \\|help" text)))
    ;; A pending permission opens the card up.
    (with-current-buffer shell
      (setf (alist-get :tool-calls agent-shell--state)
            (list (cons "t1" (list (cons :title "Edit src/auth.ts")
                                   (cons :permission-request-id 7)
                                   (cons :permission-actions
                                         (list '((:option . "Allow") (:kind . "allow_once")
                                                 (:option-id . "allow")))))))))
    (deathless-test--emit shell 'permission-request :tool-call-id "t1")
    (let* ((deathless-compact t)
           (text (deathless-test--render-text)))
      (should (string-match-p "NEEDS YOU" text))
      (should (string-match-p "Edit src/auth.ts" text))
      (should (string-match-p " Allow " text)))))

(ert-deftest deathless-test-compact-auto-without-window ()
  ;; With no window to measure, auto keeps the full cards.
  (deathless-test--with-shell (shell (deathless-test--state))
    (let ((deathless-compact 'auto))
      (should (string-match-p "Opus 5.5" (deathless-test--render-text))))))

(ert-deftest deathless-test-render-empty ()
  (let ((deathless-store--sessions (make-hash-table :test #'eq))
        (view (generate-new-buffer " *deathless-test*")))
    (unwind-protect
        (with-current-buffer view
          (deathless-mode)
          (vui-render (vui-component 'deathless-view) view)
          (vui-flush-sync)
          (should (string-match-p "No agent sessions yet" (buffer-string))))
      (kill-buffer view))))

(ert-deftest deathless-test-new-starts-in-directory ()
  ;; The shell starts with `default-directory' set to the chosen one.
  ;; The shell starts in the chosen directory, and the new shell keeps
  ;; it as its working directory rather than a wider project root.
  (let* ((dir (file-name-as-directory (make-temp-file "deathless-new-" t)))
         (old (generate-new-buffer " *old-shell*"))
         (new (generate-new-buffer " *new-shell*"))
         (shells (list old))
         (agent-shell-cwd-function nil)
         seen)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-buffers) (lambda () shells))
                  ((symbol-function 'agent-shell-new-shell)
                   (lambda ()
                     (setq seen (list default-directory
                                      (funcall agent-shell-cwd-function)))
                     (push new shells))))
          (deathless-new dir)
          (should (equal seen (list dir dir)))
          (should (equal (funcall (buffer-local-value 'agent-shell-cwd-function new))
                         dir))
          (should-not (local-variable-p 'agent-shell-cwd-function old)))
      (kill-buffer old)
      (kill-buffer new)
      (delete-directory dir))))

(ert-deftest deathless-test-new-directory-default ()
  ;; The prompt offers the directory of the session at point.
  (deathless-test--with-shell (shell (deathless-test--state))
    (with-current-buffer shell (setq default-directory "/tmp/proj/"))
    (cl-letf (((symbol-function 'deathless--buffer-at-point) (lambda () shell)))
      (should (equal (deathless--new-directory-default) "/tmp/proj/")))
    (let ((default-directory "/tmp/other/"))
      (cl-letf (((symbol-function 'deathless--buffer-at-point) #'ignore))
        (should (equal (deathless--new-directory-default) "/tmp/other/"))))))

;;;; Card layout

(defvar rat-kingdom-directory)

(defun deathless-test--working (shell cwd)
  "Make SHELL's session work in CWD, running a tool."
  (deathless-test--emit shell 'input-submitted)
  (deathless-test--emit shell 'tool-call-update :tool-call '((:title . "Run npm test")))
  (setf (deathless-session-cwd (deathless-store-get shell)) cwd))

(defun deathless-test--render-buffer (fn)
  "Render the dashboard into a scratch buffer and call FN there."
  (let ((view (generate-new-buffer " *deathless-test*")))
    (unwind-protect
        (with-current-buffer view
          (deathless-mode)
          (vui-render (vui-component 'deathless-view) view)
          (vui-flush-sync)
          (funcall fn))
      (kill-buffer view))))

(ert-deftest deathless-test-layout-default-order ()
  ;; Status, then project, then title, in compact and full cards.
  (deathless-test--with-shell (shell (deathless-test--state))
    (deathless-test--working shell "/nowhere/myproj")
    (dolist (compact '(t nil))
      (let ((deathless-compact compact))
        (should (string-match-p "\\`  . WORKING +myproj  Refactor auth middleware "
                                (deathless-test--render-text)))))))

(ert-deftest deathless-test-layout-custom-order ()
  (deathless-test--with-shell (shell (deathless-test--state))
    (deathless-test--working shell "/nowhere/myproj")
    (let ((deathless-compact t)
          (deathless-card-compact-format '(:left (title status) :right (project agent))))
      (should (string-match-p "\\` Refactor auth middleware   . WORKING +myproj  Claude\\'"
                              (string-trim-right (deathless-test--render-text)))))))

(ert-deftest deathless-test-layout-custom-part ()
  (deathless-test--with-shell (shell (deathless-test--state))
    (deathless-test--working shell "/nowhere/myproj")
    (let* ((branch "main")
           (deathless-compact t)
           (deathless-card-compact-format '(:left (status branch title) :right (clock)))
           (deathless-card-parts
            (cons (cons 'branch (lambda (_session status)
                                  (when (eq status 'working) branch)))
                  deathless-card-parts)))
      (should (string-match-p "WORKING +main  Refactor auth middleware"
                              (deathless-test--render-text)))
      ;; nil leaves the part out.
      (setq branch nil)
      (should (string-match-p "WORKING +Refactor auth middleware"
                              (deathless-test--render-text)))
      ;; A built-in part can be drawn differently.
      (let ((deathless-card-parts (cons '(title . (lambda (_s _st) "Custom title"))
                                        deathless-card-parts)))
        (should (string-match-p "WORKING +Custom title"
                                (deathless-test--render-text)))))))

(ert-deftest deathless-test-layout-fits-width ()
  (deathless-test--with-shell (shell (deathless-test--state))
    (deathless-test--working shell (concat "/nowhere/" (make-string 40 ?p)))
    (setf (deathless-session-title (deathless-store-get shell)) (make-string 200 ?t))
    (dolist (compact '(t nil))
      (let* ((deathless-compact compact)
             (line (car (split-string (deathless-test--render-text) "\n"))))
        ;; The card is indented by one column.
        (should (= (string-width line) (1+ (deathless-test--width))))
        (should (string-match-p (format " %s… " (make-string 23 ?p)) line))
        (should (string-match-p "t… " line))
        (should (string-match-p "[0-9]s\\'" line))))))

(defun deathless-test--width ()
  "Return the width cards are laid out to in a buffer with no window."
  (with-temp-buffer (deathless--width)))

(ert-deftest deathless-test-layout-aligns-titles ()
  ;; Titles line up when projects differ in length.
  (deathless-test--with-shell (shell (deathless-test--state))
    (deathless-test--working shell "/nowhere/a")
    (let ((other (generate-new-buffer " *fake-shell-2*")))
      (unwind-protect
          (progn
            (with-current-buffer other
              (setq agent-shell--state (deathless-test--state))
              (make-pipe-process :name "fake-shell-2" :buffer other :noquery t))
            (puthash other (deathless-store--sync
                            (deathless-session--create :buffer other :created (cons 0 1)))
                     deathless-store--sessions)
            (deathless-test--working other "/nowhere/longer-project")
            (let* ((deathless-compact t)
                   (lines (split-string (deathless-test--render-text) "\n" t)))
              (should (= (length lines) 2))
              (should (apply #'= (mapcar (lambda (line)
                                           (string-match "Refactor" line))
                                         lines)))))
        (let ((kill-buffer-query-functions nil))
          (kill-buffer other))))))

(ert-deftest deathless-test-layout-card-at-point ()
  ;; Whatever comes first carries the card's buffer.
  (deathless-test--with-shell (shell (deathless-test--state))
    (deathless-test--working shell "/nowhere/myproj")
    (dolist (format '((:left (status project title activity) :right (clock))
                      (:left (title status) :right (clock))
                      (:left () :right (clock))))
      (let ((deathless-compact t)
            (deathless-card-compact-format format))
        (deathless-test--render-buffer
         (lambda ()
           (should (eq (get-text-property 3 'deathless-buffer) shell))
           (goto-char (point-max))
           (skip-chars-backward " \n")
           (should (eq (deathless--buffer-at-point) shell))
           (goto-char (point-min))
           (deathless-next)
           (should (eq (deathless--buffer-at-point) shell))))))))

(ert-deftest deathless-test-project-name-worktree ()
  (let ((deathless--project-names (make-hash-table :test #'equal)))
    (should (equal (deathless--project-name "/x/rat-kingdom/worktrees/myrepo/S-1/sub")
                   "myrepo"))
    (let ((rat-kingdom-directory "/srv/rk/"))
      (should (equal (deathless--project-name "/srv/rk/worktrees/other/S-2") "other")))))

(ert-deftest deathless-test-project-name-git ()
  (skip-unless (executable-find "git"))
  (let* ((deathless--project-names (make-hash-table :test #'equal))
         (top (make-temp-file "deathless-git-" t))
         (sub (expand-file-name "a/b" top))
         (calls 0)
         (toplevel (symbol-function 'deathless--git-toplevel)))
    (unwind-protect
        (progn
          (make-directory sub t)
          (let ((default-directory top))
            (should (eql 0 (call-process "git" nil nil nil "init" "-q"))))
          (cl-letf (((symbol-function 'deathless--git-toplevel)
                     (lambda (dir) (cl-incf calls) (funcall toplevel dir))))
            (should (equal (deathless--project-name sub) (file-name-nondirectory top)))
            (should (equal (deathless--project-name sub) (file-name-nondirectory top)))
            ;; Git ran once; the second answer came from the memo.
            (should (= calls 1))))
      (delete-directory top t))))

(ert-deftest deathless-test-project-name-plain ()
  (let ((deathless--project-names (make-hash-table :test #'equal)))
    (should (equal (deathless--project-name "/nowhere/plain/") "plain"))
    (should (equal (deathless-project-name "/nowhere/plain") "plain"))))

(provide 'deathless-test)
;;; deathless-test.el ends here
