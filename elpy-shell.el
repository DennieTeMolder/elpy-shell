;;; elpy-shell.el --- Better interactive Python programming -*- lexical-binding: t -*-
;;
;; Copyright (C) 2012-2019  Jorgen Schaefer
;;
;; Author: Jorgen Schaefer <contact@jorgenschaefer.de>, Rainer Gemulla <rgemulla@gmx.de>, Gaby Launay <gaby.launay@protonmail.com>
;; Maintainer: Dennie te Molder
;; URL: https://github.com/DennieTeMolder/elpy-shell
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;; Ports interactive Python support from elpy
;;
;;; Code:

(eval-when-compile (require 'subr-x))
(require 'python)

;;;;;;;;;;;;;;;;;;;;;;
;;; User customization

(defcustom elpy-shell-display-buffer-after-send nil ;
  "Whether to display the Python shell after sending something to it."
  :type 'boolean
  :group 'elpy)

(defcustom elpy-shell-echo-output 'when-shell-not-visible
  "Whether to echo the Python shell output in the echo area after input has been sent to the shell.

  Possible choices are nil (=never), `when-shell-not-visible', or
  t (=always)."
  :type '(choice (const :tag "Never" nil)
                 (const :tag "When shell not visible" when-shell-not-visible)
                 (const :tag "Always" t))
  :group 'elpy)

(defcustom elpy-shell-echo-input t
  "Whether to echo input sent to the Python shell as input in the
shell buffer.

Truncation of long inputs can be controlled via
`elpy-shell-echo-input-lines-head' and
`elpy-shell-echo-input-lines-tail'."
  :type 'boolean
  :group 'elpy)

(defcustom elpy-shell-echo-input-cont-prompt t
  "Whether to show a continuation prompt when echoing multi-line
input to the Python shell."
  :type 'boolean
  :group 'elpy)

(defcustom elpy-shell-echo-input-lines-head 10
  "Maximum number of lines to show before truncating input echoed
in the Python shell."
  :type 'integer
  :group 'elpy)

(defcustom elpy-shell-echo-input-lines-tail 10
  "Maximum number of lines to show after truncating input echoed
in the Python shell."
  :type 'integer
  :group 'elpy)

(defcustom elpy-shell-starting-directory 'project-root
  "Directory in which Python shells will be started.

Can be `project-root' (default) to use the current project root,
`current-directory' to use the buffer current directory, or a
string indicating a specific path.

\\<elpy-mode-map>
Running python interpeters need to be restarted (with
\\[elpy-shell-kill] followed by \\[elpy-shell-switch-to-shell]) for
this option to be taken into account."
  :type '(choice (const :tag "Project root" project-root)
                 (const :tag "Current directory" current-directory)
                 (string :tag "Specific directory"))
  :group 'elpy)

(defcustom elpy-shell-cell-boundary-regexp
  (concat "^\\(?:"
          "##.*" "\\|"
          "#\\s-*<.+>" "\\|"
          "#\\s-*\\(?:In\\|Out\\)\\[.*\\]:"
          "\\)\\s-*$")
  "Regular expression for matching a line indicating the boundary
of a cell (beginning or ending). By default, lines starting with
``##`` are treated as a cell boundaries, as are the boundaries in
Python files exported from IPython or Jupyter notebooks (e.g.,
``# <markdowncell>``, ``# In[1]:'', or ``# Out[1]:``).

Note that `elpy-shell-cell-beginning-regexp' must also match
the first boundary of the code cell."

  :type 'string
  :group 'elpy)

(defcustom elpy-shell-codecell-beginning-regexp
  (concat "^\\(?:"
          "##.*" "\\|"
          "#\\s-*<codecell>" "\\|"
          "#\\s-*In\\[.*\\]:"
          "\\)\\s-*$")
  "Regular expression for matching a line indicating the
beginning of a code cell. By default, lines starting with ``##``
are treated as beginnings of a code cell, as are the code cell
beginnings (and only the code cell beginnings) in Python files
exported from IPython or Jupyter notebooks (e.g., ``#
<codecell>`` or ``# In[1]:``).

Note that `elpy-shell-cell-boundary-regexp' must also match
the code cell beginnings defined here."
  :type 'string
  :group 'elpy)

(defcustom elpy-shell-add-to-shell-history nil
  "If Elpy should make the code sent to the shell available in the
shell history. This allows to use `comint-previous-input' in the
python shell to get back the pieces of code sent by Elpy. This affects
the following functions:
- `elpy-shell-send-statement'
- `elpy-shell-send-top-statement'
- `elpy-shell-send-group'
- `elpy-shell-send-codecell'
- `elpy-shell-send-region-or-buffer'."
  :type 'boolean
  :group 'elpy)

(defcustom elpy-shell-darwin-use-pty nil
  "Whether to connect to the Python shell through pty on MacOS.

If nil, Elpy will connect to Python through a pipe. Any non-nil
value will cause Elpy use a pseudo-terminal (pty) instead. This
value should be set to nil when using a Python interpreter that
uses the libedit version of Readline, such as the default MacOS
Python interpreters. This value can be safely be set to true when
using a version of Python that uses GNU Readline.

This value is only used when `elpy-shell-get-or-create-process'
creates a new Python process."
  :type 'boolean
  :group 'elpy)

;;;;;;;;;;;;;;;;;;
;;; Projects

(defcustom elpy-project-root nil
  "The root of the project the current buffer is in.

There is normally no use in setting this variable directly, as
Elpy tries to detect the project root automatically. See
`elpy-project-root-finder-functions' for a way of influencing
this.

Setting this variable globally will override Elpy's automatic
project detection facilities entirely.

Alternatively, you can set this in file- or directory-local
variables using \\[add-file-local-variable] or
\\[add-dir-local-variable].

Do not use this variable in Emacs Lisp programs. Instead, call
the `elpy-project-root' function. It will do the right thing."
  :type 'directory
  :safe 'file-directory-p
  :group 'elpy)
(make-variable-buffer-local 'elpy-project-root)

(defcustom elpy-project-root-finder-functions
  '(elpy-project-find-projectile-root
    elpy-project-find-python-root
    elpy-project-find-git-root
    elpy-project-find-hg-root
    elpy-project-find-svn-root)
  "List of functions to ask for the current project root.

These will be checked in turn. The first directory found is used."
  :type '(set (const :tag "Projectile project root"
                     elpy-project-find-projectile-root)
              (const :tag "Python project (setup.py, setup.cfg)"
                     elpy-project-find-python-root)
              (const :tag "Git repository root (.git)"
                     elpy-project-find-git-root)
              (const :tag "Mercurial project root (.hg)"
                     elpy-project-find-hg-root)
              (const :tag "Subversion project root (.svn)"
                     elpy-project-find-svn-root)
              (const :tag "Django project root (manage.py, django-admin.py)"
                     elpy-project-find-django-root))
  :group 'elpy)

(defun elpy-project-root ()
  "Return the root of the current buffer's project.

This can very well be nil if the current file is not part of a
project.

See `elpy-project-root-finder-functions' for a way to configure
how the project root is found. You can also set the variable
`elpy-project-root' in, for example, .dir-locals.el to override
this."
  (unless elpy-project-root
    (setq elpy-project-root
          (run-hook-with-args-until-success
           'elpy-project-root-finder-functions)))
  elpy-project-root)

(defun elpy-set-project-root (new-root)
  "Set the Elpy project root to NEW-ROOT."
  (interactive "DNew project root: ")
  (setq elpy-project-root new-root))

(defun elpy-project-find-python-root ()
  "Return the current Python project root, if any.

This is marked with 'setup.py', 'setup.cfg' or 'pyproject.toml'."
  (or (locate-dominating-file default-directory "setup.py")
      (locate-dominating-file default-directory "setup.cfg")
      (locate-dominating-file default-directory "pyproject.toml")))

(defun elpy-project-find-git-root ()
  "Return the current git repository root, if any."
  (locate-dominating-file default-directory ".git"))

(defun elpy-project-find-hg-root ()
  "Return the current git repository root, if any."
  (locate-dominating-file default-directory ".hg"))

(defun elpy-project-find-svn-root ()
  "Return the current git repository root, if any."
  (locate-dominating-file default-directory
                          (lambda (dir)
                            (and (file-directory-p (format "%s/.svn" dir))
                                 (not (file-directory-p (format "%s/../.svn"
                                                                dir)))))))

(defun elpy-project-find-projectile-root ()
  "Return the current project root according to projectile."
  ;; `ignore-errors' both to avoid an unbound function error as well
  ;; as ignore projectile saying there is no project root here.
  (ignore-errors
    (projectile-project-root)))


;;;;;;;;;;;;;;;;;;
;;; Nav commands

(defun elpy-nav-forward-block ()
  "Move to the next line indented like point.

This will skip over lines and statements with different
indentation levels."
  (interactive "^")
  (let ((indent (current-column))
        (start (point))
        (cur nil))
    (when (/= (% indent python-indent-offset)
              0)
      (setq indent (* (1+ (/ indent python-indent-offset))
                      python-indent-offset)))
    (python-nav-forward-statement)
    (while (and (< indent (current-indentation))
                (not (eobp)))
      (when (equal (point) cur)
        (error "Statement does not finish"))
      (setq cur (point))
      (python-nav-forward-statement))
    (when (< (current-indentation)
             indent)
      (goto-char start))))

(defun elpy-nav-backward-block ()
  "Move to the previous line indented like point.

This will skip over lines and statements with different
indentation levels."
  (interactive "^")
  (let ((indent (current-column))
        (start (point))
        (cur nil))
    (when (/= (% indent python-indent-offset)
              0)
      (setq indent (* (1+ (/ indent python-indent-offset))
                      python-indent-offset)))
    (python-nav-backward-statement)
    (while (and (< indent (current-indentation))
                (not (bobp)))
      (when (equal (point) cur)
        (error "Statement does not start"))
      (setq cur (point))
      (python-nav-backward-statement))
    (when (< (current-indentation)
             indent)
      (goto-char start))))

;;;;;;;;;;;;;;;;;;
;;; Shell commands

(defvar elpy--shell-last-py-buffer nil
  "Help keep track of python buffer when changing to pyshell.")

(defun elpy-shell-display-buffer ()
  "Display inferior Python process buffer."
  (display-buffer (process-buffer (elpy-shell-get-or-create-process))
                  nil
                  'visible))

;; better name would be pop-to-shell
;;;###autoload
(defun elpy-shell-switch-to-shell ()
  "Switch to inferior Python process buffer."
  (interactive)
  (setq elpy--shell-last-py-buffer (buffer-name))
  (pop-to-buffer (process-buffer (elpy-shell-get-or-create-process))))

(defun elpy-shell-switch-to-buffer ()
  "Switch from inferior Python process buffer to recent Python buffer."
  (interactive)
  (pop-to-buffer elpy--shell-last-py-buffer))

;;;###autoload
(defun elpy-shell-switch-to-shell-in-current-window ()
  (interactive)
  (setq elpy--shell-last-py-buffer (buffer-name))
  (switch-to-buffer (process-buffer (elpy-shell-get-or-create-process))))

(defun elpy-shell-switch-to-buffer-in-current-window ()
  (interactive)
  (switch-to-buffer elpy--shell-last-py-buffer))

(defun elpy-shell-kill (&optional kill-buff)
  "Kill the current python shell.

If KILL-BUFF is non-nil, also kill the associated buffer."
  (interactive)
  (let ((shell-buffer (python-shell-get-buffer)))
    (cond
     (shell-buffer
      (delete-process shell-buffer)
      (when kill-buff
	(kill-buffer shell-buffer))
      (message "Killed %s shell" shell-buffer))
     (t
      (message "No python shell to kill")))))

(defun elpy-shell-kill-all (&optional kill-buffers ask-for-each-one)
  "Kill all active python shells.

If KILL-BUFFERS is non-nil, also kill the associated buffers.
If ASK-FOR-EACH-ONE is non-nil, ask before killing each python process."
  (interactive)
  (let ((python-buffer-list ()))
    ;; Get active python shell buffers and kill inactive ones (if asked)
    (cl-loop for buffer being the buffers do
	  (when (and (buffer-name buffer)
		     (string-match (rx bol "*Python" (opt "[" (* (not (any "]"))) "]") "*" eol)
				   (buffer-name buffer)))
	    (if (get-buffer-process buffer)
		(push buffer python-buffer-list)
	      (when kill-buffers
		(kill-buffer buffer)))))
    (cond
     ;; Ask for each buffers and kill
     ((and python-buffer-list ask-for-each-one)
      (cl-loop for buffer in python-buffer-list do
	    (when (y-or-n-p (format "Kill %s ? " buffer))
		(delete-process buffer)
		(when kill-buffers
		  (kill-buffer buffer)))))
     ;; Ask and kill every buffers
     (python-buffer-list
      (if (y-or-n-p (format "Kill %s python shells ? " (length python-buffer-list)))
	  (cl-loop for buffer in python-buffer-list do
		(delete-process buffer)
		(when kill-buffers
		  (kill-buffer buffer)))))
     ;; No shell to close
     (t
      (message "No python shell to close")))))

(defun elpy-executable-find-remote (command)
  "Emulate 'executable-find' COMMAND with REMOTE as t.
Since Emacs 27, 'executable-find' accepts the 2nd argument.
REMOVE THIS when Elpy no longer supports Emacs 26."
  (if (cdr (help-function-arglist 'executable-find)) ; 27+
      (executable-find command t)
    (if (file-remote-p default-directory)
        (let ((res (locate-file ; code from files.el
	            command
	            (mapcar
	             (lambda (x) (concat (file-remote-p default-directory) x))
	             (exec-path))
	            exec-suffixes 'file-executable-p)))
          (when (stringp res) (file-local-name res)))
      (executable-find command)))) ; local search

(defun elpy-shell-get-or-create-process (&optional sit)
  "Get or create an inferior Python process for current buffer and return it.

If SIT is non-nil, sit for that many seconds after creating a
Python process. This allows the process to start up."
  (let* ((process-connection-type
          (if (string-equal system-type "darwin") elpy-shell-darwin-use-pty t))  ;; see https://github.com/jorgenschaefer/elpy/pull/1671
         (bufname (format "*%s*" (python-shell-get-process-name nil)))
         (proc (get-buffer-process bufname)))
    (if proc
        proc
      (unless (elpy-executable-find-remote python-shell-interpreter)
        (error "Python shell interpreter `%s' cannot be found. Please set `python-shell-interpreter' to a valid python binary!"
               python-shell-interpreter))
      (let ((default-directory
              (cond ((eq elpy-shell-starting-directory 'project-root)
                     (or (elpy-project-root)
                         default-directory))
                    ((eq elpy-shell-starting-directory 'current-directory)
                     default-directory)
                    ((stringp elpy-shell-starting-directory)
                     (file-name-as-directory
                      (expand-file-name elpy-shell-starting-directory)))
                    (t
                     (error "Wrong value for `elpy-shell-starting-directory', please check this variable documentation and set it to a proper value")))))
        ;; We cannot use `run-python` directly, as it selects the new shell
        ;; buffer. See https://github.com/jorgenschaefer/elpy/issues/1848
        (python-shell-make-comint
         (python-shell-calculate-command)
         (python-shell-get-process-name nil)
         t))
      (when sit (sit-for sit))
      (get-buffer-process bufname))))

(defun elpy-shell--send-setup-code ()
  "Send setup code for the shell."
  (let ((process (python-shell-get-process)))
    (when (elpy-project-root)
      (python-shell-send-string-no-output
       (format "import sys;sys.path.append('%s');del sys"
               (elpy-project-root))
       process))))

(defun elpy-shell-toggle-dedicated-shell (&optional arg)
  "Toggle the use of a dedicated python shell for the current buffer.

if ARG is positive, enable the use of a dedicated shell.
if ARG is negative or 0, disable the use of a dedicated shell."
  (interactive)
  (let ((arg (or arg
                 (if (local-variable-p 'python-shell-buffer-name) 0 1))))
    (if (<= arg 0)
        (kill-local-variable 'python-shell-buffer-name)
      (setq-local python-shell-buffer-name
                  (format "Python[%s]"
                          (file-name-sans-extension
                          (buffer-name)))))))

(defun elpy-shell-set-local-shell (&optional shell-name)
  "Associate the current buffer to a specific shell.

Meaning that the code from the current buffer will be sent to this shell.

If SHELL-NAME is not specified, ask with completion for a shell name.

If SHELL-NAME is \"Global\", associate the current buffer to the main python
shell (often \"*Python*\" shell)."
  (interactive)
  (let* ((current-shell-name (if (local-variable-p 'python-shell-buffer-name)
                                 (progn
                                   (string-match "Python\\[\\(.*?\\)\\]"
                                                 python-shell-buffer-name)
                                   (match-string 1 python-shell-buffer-name))
                               "Global"))
         (shell-names (cl-loop
                for buffer in (buffer-list)
                for buffer-name = (file-name-sans-extension (substring-no-properties (buffer-name buffer)))
                if (string-match "\\*Python\\[\\(.*?\\)\\]\\*" buffer-name)
                collect (match-string 1 buffer-name)))
         (candidates (remove current-shell-name
                           (delete-dups
                           (append (list (file-name-sans-extension
                                          (buffer-name)) "Global")
                                   shell-names))))
         (prompt (format "Shell name (current: %s): " current-shell-name))
         (shell-name (or shell-name (completing-read prompt candidates))))
    (if (string= shell-name "Global")
       (kill-local-variable 'python-shell-buffer-name)
      (setq-local python-shell-buffer-name (format "Python[%s]" shell-name)))))

(defun elpy-shell--ensure-shell-running ()
  "Ensure that the Python shell for the current buffer is running.

If the shell is not running, waits until the first prompt is visible and
commands can be sent to the shell."
  (with-current-buffer (process-buffer (elpy-shell-get-or-create-process))
    (let ((cumtime 0))
      (while (and (when (boundp 'python-shell--first-prompt-received)
                    (not python-shell--first-prompt-received))
                  (< cumtime 3))
        (sleep-for 0.1)
        (setq cumtime (+ cumtime 0.1)))))
  (elpy-shell-get-or-create-process))

(defun elpy-shell--string-without-indentation (string)
  "Return the current string, but without indentation."
  (if (string-empty-p string)
      string
    (let ((indent-level nil)
          (indent-tabs-mode nil))
      (with-temp-buffer
        (insert string)
        (goto-char (point-min))
        (while (< (point) (point-max))
          (cond
           ((or (elpy-shell--current-line-only-whitespace-p)
                (python-info-current-line-comment-p)))
           ((not indent-level)
            (setq indent-level (current-indentation)))
           ((and indent-level
                 (< (current-indentation) indent-level))
            (error (message "X%sX" (thing-at-point 'line)))))
          ;; (error "Can't adjust indentation, consecutive lines indented less than starting line")))
          (forward-line))
        (indent-rigidly (point-min)
                        (point-max)
                        (- indent-level))
        ;; 'indent-rigidly' introduces tabs despite the fact that 'indent-tabs-mode' is nil
        ;; 'untabify' fix that
        (untabify (point-min) (point-max))
        (buffer-string)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Flash input sent to shell

;; functions for flashing a region; only flashes when package eval-sexp-fu is
;; loaded and its minor mode enabled
(defun elpy-shell--flash-and-message-region (begin end)
  "Displays information about code fragments sent to the shell.

BEGIN and END refer to the region of the current buffer
containing the code being sent. Displays a message with the code
on the first line of that region. If `eval-sexp-fu-flash-mode' is
active, additionally flashes that region briefly."
  (when (> end begin)
    (save-excursion
      (let* ((bounds
              (save-excursion
                (goto-char begin)
                (bounds-of-thing-at-point 'line)))
             (begin (max begin (car bounds)))
             (end (min end (cdr bounds)))
             (code-on-first-line (string-trim (buffer-substring begin end))))
        (goto-char begin)
        (end-of-line)
        (if (<= end (point))
            (message "Sent: %s" code-on-first-line)
          (message "Sent: %s..." code-on-first-line))
        (when (bound-and-true-p eval-sexp-fu-flash-mode)
          (cl-multiple-value-bind (_bounds hi unhi _eflash)
              (eval-sexp-fu-flash (cons begin end))
            (eval-sexp-fu-flash-doit (lambda () t) hi unhi)))))))

;;;;;;;;;;;;;;;;;;;
;; Helper functions

(defun elpy-shell--current-line-else-or-elif-p ()
  (eq (string-match-p "\\s-*el\\(?:se:\\|if[^\w]\\)" (thing-at-point 'line)) 0))

(defun elpy-shell--current-line-decorator-p ()
  (eq (string-match-p "^\\s-*@[A-Za-z]" (thing-at-point 'line)) 0))

(defun elpy-shell--current-line-decorated-defun-p ()
  (save-excursion  (python-nav-backward-statement)
                   (elpy-shell--current-line-decorator-p)))

(defun elpy-shell--current-line-indented-p ()
  (eq (string-match-p "\\s-+[^\\s-]+" (thing-at-point 'line)) 0))

(defun elpy-shell--current-line-only-whitespace-p ()
  "Whether the current line contains only whitespace characters (or is empty)."
  (eq (string-match-p "\\s-*$" (thing-at-point 'line)) 0))

(defun elpy-shell--current-line-code-line-p ()
  (and (not (elpy-shell--current-line-only-whitespace-p))
       (not (python-info-current-line-comment-p))))

(defun elpy-shell--current-line-defun-p ()
  "Whether a function definition starts at the current line."
  (eq (string-match-p
       "\\s-*\\(?:def\\|async\\s-+def\\)\\s\-"
       (thing-at-point 'line))
      0))

(defun elpy-shell--current-line-defclass-p ()
  "Whether a class definition starts at the current line."
  (eq (string-match-p
       "\\s-*class\\s\-"
       (thing-at-point 'line))
      0))

(defun elpy-shell--skip-to-next-code-line (&optional backwards)
  "Move the point to the next line containing code.

If the current line has code, point is not moved. If BACKWARDS is
non-nil, skips backwards."
  (if backwards
      (while (and (not (elpy-shell--current-line-code-line-p))
                  (not (eq (point) (point-min))))
        (forward-line -1))
    (while (and (not (elpy-shell--current-line-code-line-p))
                (not (eq (point) (point-max))))
      (forward-line))))

(defun elpy-shell--check-if-shell-available ()
  "Check if the associated python shell is available.

Return non-nil is the shell is running and not busy, nil otherwise."
  (and (python-shell-get-process)
       (with-current-buffer (process-buffer (python-shell-get-process))
         (save-excursion
           (goto-char (point-max))
           (let ((inhibit-field-text-motion t))
             (python-shell-comint-end-of-output-p
              (buffer-substring (line-beginning-position)
                                (line-end-position))))))))
;;;;;;;;;;
;; Echoing

(defmacro elpy-shell--with-maybe-echo (body)
  ;; Echoing is apparently buggy for emacs < 25...
  (if (<= 25 emacs-major-version)
      `(elpy-shell--with-maybe-echo-output
        (elpy-shell--with-maybe-echo-input
         ,body))
    body))


(defmacro elpy-shell--with-maybe-echo-input (body)
  "Run BODY so that it adheres `elpy-shell-echo-input' and `elpy-shell-display-buffer'."
  `(progn
     (elpy-shell--enable-echo)
     (prog1
         (if elpy-shell-display-buffer-after-send
             (prog1 (progn ,body)
               (elpy-shell-display-buffer))
           (cl-flet ((elpy-shell-display-buffer () ()))
             (progn ,body)))
       (elpy-shell--disable-echo))))

(defvar-local elpy-shell--capture-output nil
  "Non-nil when the Python shell should capture output for display in the echo area.")

(defvar-local elpy-shell--captured-output nil
  "Current captured output of the Python shell.")

(defmacro elpy-shell--with-maybe-echo-output (body)
  "Run BODY and grab shell output according to `elpy-shell-echo-output'."
  `(cl-letf (((symbol-function 'python-shell-send-file)
              (if elpy-shell-echo-output
                  (symbol-function 'elpy-shell-send-file)
                (symbol-function 'python-shell-send-file))))
     (let* ((process (elpy-shell--ensure-shell-running))
            (process-buf (process-buffer process))
            (shell-visible (or elpy-shell-display-buffer-after-send
                               (get-buffer-window process-buf))))
       (with-current-buffer process-buf
         (setq-local elpy-shell--capture-output
                     (and elpy-shell-echo-output
                          (or (not (eq elpy-shell-echo-output 'when-shell-not-visible))
                              (not shell-visible)))))
       (progn ,body))))

(defun elpy-shell--enable-output-filter ()
    (add-hook 'comint-output-filter-functions 'elpy-shell--output-filter nil t))

(defun elpy-shell--output-filter (string)
  "Filter used in `elpy-shell--with-maybe-echo-output' to grab output.

No actual filtering is performed. STRING is the output received
to this point from the process. If `elpy-shell--capture-output'
is set, captures and messages shell output in the echo area (once
complete). Otherwise, does nothing."
  ;; capture the output and message it when complete
  (when elpy-shell--capture-output
    ;; remember the new output
    (setq-local elpy-shell--captured-output
                (concat elpy-shell--captured-output (ansi-color-filter-apply string)))

    ;; Output ends when `elpy-shell--captured-output' contains
    ;; the prompt attached at the end of it. If so, message it.
    (when (python-shell-comint-end-of-output-p elpy-shell--captured-output)
      (let ((output (substring
                     elpy-shell--captured-output
                     0 (match-beginning 0)))
            (message-log-max))
        (if (string-match-p "Traceback (most recent call last):" output)
            (message "Exception during evaluation.")
          (if (string-empty-p output)
              (message "No output was produced.")
            (message "%s" (replace-regexp-in-string "\n\\'" "" output))))
        (setq-local elpy-shell--captured-output nil))))

  ;; return input unmodified
  string)

(defun elpy-shell--insert-and-font-lock (string face &optional no-font-lock)
  "Inject STRING into the Python shell buffer."
  (let ((from-point (point)))
    (insert string)
    (if (not no-font-lock)
        (add-text-properties from-point (point)
                             (list 'front-sticky t 'font-lock-face face)))))

(defun elpy-shell--append-to-shell-output (string &optional no-font-lock prepend-cont-prompt)
  "Append the given STRING to the output of the Python shell buffer.

Unless NO-FONT-LOCK is set, formats STRING as shell input.
Prepends a continuation promt if PREPEND-CONT-PROMPT is set."
  (unless (string-empty-p string)
  (let* ((process (elpy-shell-get-or-create-process))
         (process-buf (process-buffer process))
         (mark-point (process-mark process)))
    (with-current-buffer process-buf
      (save-excursion
        (goto-char mark-point)
        (if prepend-cont-prompt
            (let* ((column (+ (- (point)
                                 (let ((inhibit-field-text-motion t))
                                   (forward-line -1)
                                   (end-of-line)
                                   (point)))
                              1))
                   (prompt (concat (make-string (max 0 (- column 6)) ? ) "... "))
                   (lines (split-string string "\n")))
              (goto-char mark-point)
              (elpy-shell--insert-and-font-lock
               (car lines) 'comint-highlight-input no-font-lock)
              (when (cdr lines)
                  ;; no additional newline at end for multiline
                  (dolist (line (cdr lines))
                    (insert "\n")
                    (let ((from-point (point)))
                      (elpy-shell--insert-and-font-lock
                       prompt 'comint-highlight-prompt no-font-lock)
                      (add-text-properties
                       from-point (point)
                       '(field output inhibit-line-move-field-capture t
                               rear-nonsticky t)))
                    (elpy-shell--insert-and-font-lock
                     line 'comint-highlight-input no-font-lock)))
                ;; but put one for single line
                (insert "\n"))
          (elpy-shell--insert-and-font-lock
           string 'comint-highlight-input no-font-lock))
        (set-marker (process-mark process) (point)))))))

(defun elpy-shell--string-head-lines (string n)
  "Extract the first N lines from STRING."
  (let* ((line "\\(?:\\(?:.*\n\\)\\|\\(?:.+\\'\\)\\)")
         (lines (concat line "\\{" (number-to-string n) "\\}"))
         (regexp (concat "\\`" "\\(" lines "\\)")))
    (if (string-match regexp string)
        (match-string 1 string)
      string)))

(defun elpy-shell--string-tail-lines (string n)
  "Extract the last N lines from STRING."
  (let* ((line "\\(?:\\(?:.*\n\\)\\|\\(?:.+\\'\\)\\)")
         (lines (concat line "\\{" (number-to-string n) "\\}"))
         (regexp (concat "\\(" lines "\\)" "\\'")))
    (if (string-match regexp string)
        (match-string 1 string)
      string)))

(defun elpy-shell--python-shell-send-string-echo-advice (string &optional _process _msg)
  "Advice to enable echoing of input in the Python shell."
  (interactive)
  (let* ((append-string ; strip setup code from Elpy
          (if (string-match "import sys, codecs, os, ast;__pyfile = codecs.open.*$" string)
              (replace-match "" nil nil string)
            string))
         (append-string ; strip setup code from python.el
          (if (string-match "import codecs, os;__pyfile = codecs.open(.*;exec(compile(__code, .*$" append-string)
              (replace-match "" nil nil append-string)
            append-string))
         (append-string ; here too
          (if (string-match "^# -\\*- coding: utf-8 -\\*-\n*$" append-string)
              (replace-match "" nil nil append-string)
            append-string))
         (append-string ; Strip "if True:", added when sending regions
          (if (string-match "^if True:$" append-string)
              (replace-match "" nil nil append-string)
            append-string))
         (append-string ; strip newlines from beginning and white space from end
          (string-trim-right
           (if (string-match "\\`\n+" append-string)
               (replace-match "" nil nil append-string)
             append-string)))
         (append-string ; Dedent region
          (elpy-shell--string-without-indentation append-string))
         (head (elpy-shell--string-head-lines append-string elpy-shell-echo-input-lines-head))
         (tail (elpy-shell--string-tail-lines append-string elpy-shell-echo-input-lines-tail))
         (append-string (if (> (length append-string) (+ (length head) (length tail)))
                            (concat head "...\n" tail)
                          append-string)))

    ;; append the modified string to the shell output; prepend a newline for
    ;; multi-line strings
    (if elpy-shell-echo-input-cont-prompt
        (elpy-shell--append-to-shell-output append-string nil t)
      (elpy-shell--append-to-shell-output
       (concat (if (string-match "\n" append-string) "\n" "")
               append-string
               "\n")))))

(defun elpy-shell--enable-echo ()
  "Enable input echoing when `elpy-shell-echo-input' is set."
  (when elpy-shell-echo-input
    (advice-add 'python-shell-send-string
                :before 'elpy-shell--python-shell-send-string-echo-advice)))

(defun elpy-shell--disable-echo ()
  "Disable input echoing."
  (advice-remove 'python-shell-send-string
                 'elpy-shell--python-shell-send-string-echo-advice))

;;;###autoload
(defun elpy-shell-send-file (file-name &optional process temp-file-name
                                         delete msg)
  "Like `python-shell-send-file' but evaluates last expression separately.

See `python-shell-send-file' for a description of the
arguments. This function differs in that it breaks up the
Python code in FILE-NAME into statements. If the last statement
is a Python expression, it is evaluated separately in 'eval'
mode. This way, the interactive python shell can capture (and
print) the output of the last expression."
  (interactive
   (list
    (read-file-name "File to send: ")   ; file-name
    nil                                 ; process
    nil                                 ; temp-file-name
    nil                                 ; delete
    t))                                 ; msg
  (let* ((process (or process (python-shell-get-process-or-error msg)))
         (encoding (with-temp-buffer
                     (insert-file-contents
                      (or temp-file-name file-name))
                     (python-info-encoding)))
         (file-name (expand-file-name
                     (or (file-remote-p file-name 'localname)
                         file-name)))
         (temp-file-name (when temp-file-name
                           (expand-file-name
                            (or (file-remote-p temp-file-name 'localname)
                                temp-file-name)))))
    (python-shell-send-string
     (format
      (concat
       "import sys, codecs, os, ast;"
       "__pyfile = codecs.open('''%s''', encoding='''%s''');"
       "__code = __pyfile.read().encode('''%s''');"
       "__pyfile.close();"
       (when (and delete temp-file-name)
         (format "os.remove('''%s''');" temp-file-name))
       "__block = ast.parse(__code, '''%s''', mode='exec');"
       ;; Has to ba a oneliner, which make conditionnal statements a bit complicated...
       " __block.body = (__block.body if not isinstance(__block.body[0], ast.If) else __block.body if not isinstance(__block.body[0].test, ast.Name) else __block.body if not __block.body[0].test.id == 'True' else __block.body[0].body) if sys.version_info[0] < 3 else (__block.body if not isinstance(__block.body[0], ast.If) else __block.body if not isinstance(__block.body[0].test, ast.NameConstant) else __block.body if not __block.body[0].test.value is True else __block.body[0].body);"
       "__last = __block.body[-1];" ;; the last statement
       "__isexpr = isinstance(__last,ast.Expr);" ;; is it an expression?
       "_ = __block.body.pop() if __isexpr else None;" ;; if so, remove it
       "exec(compile(__block, '''%s''', mode='exec'));" ;; execute everything else
       "eval(compile(ast.Expression(__last.value), '''%s''', mode='eval')) if __isexpr else None" ;; if it was an expression, it has been removed; now evaluate it
       )
      (or temp-file-name file-name) encoding encoding file-name file-name file-name)
     process)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Navigation commands for sending

(defun elpy-shell--nav-beginning-of-statement ()
  "Move the point to the beginning of the current or next Python statement.

If the current line starts with a statement, behaves exactly like
`python-nav-beginning-of-statement'. If the line is part of a
statement but not a statement itself, goes backwards to the
beginning of the statement. If the current line is not a code
line, skips forward to the next code line and navigates from
there."
  (elpy-shell--skip-to-next-code-line)
  (python-nav-beginning-of-statement)
  (let ((p))
    (while (and (not (eq p (point)))
                (or (elpy-shell--current-line-else-or-elif-p)
                    (elpy-shell--current-line-decorated-defun-p)))
      (elpy-nav-backward-block)
      (setq p (point)))))

(defun elpy-shell--nav-end-of-statement ()
  "Move the point to the end of the current Python statement.

Assumes that the point is precisely at the beginning of a
statement (e.g., after calling
`elpy-shell--nav-beginning-of-statement')."
  (let ((continue t)
        (p))
    (while (and (not (eq p (point)))
                continue)
      ;; if on a decorator, move to the associated function
      (when (elpy-shell--current-line-decorator-p)
        (elpy-nav-forward-block))

      ;; check if there is a another block at the same indentation level
      (setq p (point))
      (elpy-nav-forward-block)

      ;; if not, go to the end of the block and done
      (if (eq p (point))
          (progn
            (python-nav-end-of-block)
            (setq continue nil))
        ;; otherwise check if its an else/elif clause
        (unless (elpy-shell--current-line-else-or-elif-p)
          (forward-line -1)
          (elpy-shell--skip-to-next-code-line t)
          (setq continue nil)))))
  (end-of-line))

(defun elpy-shell--nav-beginning-of-top-statement ()
  "Move the point to the beginning of the current or next top-level statement.

If the point is within a top-level statement, moves to its
beginning. Otherwise, moves to the beginning of the next top-level
statement."
  (interactive)
  (elpy-shell--nav-beginning-of-statement)
  (let ((p))
    (while (and (not (eq p (point)))
                (elpy-shell--current-line-indented-p))
      (forward-line -1)
      (elpy-shell--skip-to-next-code-line t)
      (elpy-shell--nav-beginning-of-statement))))

(defun elpy-shell--nav-beginning-of-def (def-p)
  "Move point to the beginning of the current definition.

DEF-P is a predicate function that decides whether the current
line starts a definition.

It the current line starts a definition, uses this definition. If
the current line does not start a definition and is a code line,
searches for the definition that contains the current line.
Otherwise, searches for the definition that contains the next
code line.

If a definition is found, moves point to the start of the
definition and returns t. Otherwise, retains point position and
returns nil."
  (if (funcall def-p)
      (progn
        (python-nav-beginning-of-statement)
        t)
    (let ((beg-ts (save-excursion
                    (elpy-shell--skip-to-next-code-line t)
                    (elpy-shell--nav-beginning-of-top-statement)
                    (point)))
          (orig-p (point))
          (max-indent (save-excursion
                        (elpy-shell--skip-to-next-code-line)
                        (- (current-indentation) 1)))
          (found))
      (while (and (not found)
                  (>= (point) beg-ts))
        (if (and (funcall def-p)
                 (<= (current-indentation) max-indent))
            (setq found t)
          (when (elpy-shell--current-line-code-line-p)
            (setq max-indent (min max-indent
                                  (- (current-indentation) 1))))
          (forward-line -1)))
      (if found
          (python-nav-beginning-of-statement)
        (goto-char orig-p))
      found)))

(defun elpy-shell--nav-beginning-of-defun ()
  "Move point to the beginning of the current function definition.

If a definition is found, moves point to the start of the
definition and returns t. Otherwise, retains point position and
returns nil.

See `elpy-shell--nav-beginning-of-def' for details."
  (when (or (elpy-shell--nav-beginning-of-def 'elpy-shell--current-line-defun-p)
            (elpy-shell--current-line-decorator-p))
    (when (elpy-shell--current-line-decorated-defun-p)
      (python-nav-backward-statement))
    t))

(defun elpy-shell--nav-beginning-of-defclass ()
  "Move point to the beginning of the current class definition.

If a definition is found, moves point to the start of the
definition and returns t. Otherwise, retains point position and
returns nil.

See `elpy-shell--nav-beginning-of-def' for details."
  (elpy-shell--nav-beginning-of-def 'elpy-shell--current-line-defclass-p))

(defun elpy-shell--nav-beginning-of-group ()
  "Move point to the beginning of the current or next group of top-level statements.

A sequence of top-level statements is a group if they are not
separated by empty lines. Empty lines within each top-level
statement are ignored.

If the point is within a top-level statement, moves to the
beginning of the group containing this statement. Otherwise, moves
to the first top-level statement below point."
  (elpy-shell--nav-beginning-of-top-statement)
  (while (not (or (elpy-shell--current-line-only-whitespace-p)
                  (eq (point) (point-min))))
    (unless (python-info-current-line-comment-p)
      (elpy-shell--nav-beginning-of-top-statement))
    (forward-line -1)
    (beginning-of-line))
  (when (elpy-shell--current-line-only-whitespace-p)
    (forward-line 1)
    (beginning-of-line)))

;;;;;;;;;;;;;;;;;
;;; Send commands

;;;###autoload
(defun elpy-shell-send-statement-and-step ()
  "Send current or next statement to Python shell and step.

If the current line is part of a statement, sends this statement.
Otherwise, skips forward to the next code line and sends the
corresponding statement."
  (interactive)
  (elpy-shell--ensure-shell-running)
  (elpy-shell--nav-beginning-of-statement)
  ;; Make sure there is a statement to send
  (unless (looking-at "[[:space:]]*$")
    (unless elpy-shell-echo-input (elpy-shell--append-to-shell-output "\n"))
    (let ((beg (save-excursion (beginning-of-line) (point)))
          (end (progn (elpy-shell--nav-end-of-statement) (point))))
      (unless (eq beg end)
        (elpy-shell--flash-and-message-region beg end)
        (elpy-shell--add-to-shell-history (buffer-substring beg end))
        (elpy-shell--with-maybe-echo
         (python-shell-send-string
          (python-shell-buffer-substring beg end)))))
    (python-nav-forward-statement)))

;;;###autoload
(defun elpy-shell-send-top-statement-and-step ()
  "Send the current or next top-level statement to the Python shell and step.

If the current line is part of a top-level statement, sends this
top-level statement. Otherwise, skips forward to the next code
line and sends the corresponding top-level statement."
  (interactive)
  (elpy-shell--ensure-shell-running)
  (let* ((beg (progn (elpy-shell--nav-beginning-of-top-statement) (point)))
         (end (progn (elpy-shell--nav-end-of-statement) (point))))
    (elpy-shell--flash-and-message-region beg end)
    (if (string-match-p "\\`[^\n]*\\'" (buffer-substring beg end))
        ;; single line
        (elpy-shell-send-statement-and-step)
      ;; multiple lines
      (elpy-shell--add-to-shell-history (buffer-substring beg end))
      (elpy-shell--with-maybe-echo
       (python-shell-send-string (python-shell-buffer-substring beg end)))
      (setq mark-active nil)
      (python-nav-forward-statement))))

;;;###autoload
(defun elpy-shell-send-defun-and-step ()
  "Send the function definition that contains the current line
to the Python shell and steps.

See `elpy-shell--nav-beginning-of-def' for details."
  (interactive)
  (if (elpy-shell--nav-beginning-of-defun)
      (elpy-shell-send-statement-and-step)
    (message "There is no function definition that includes the current line.")))

;;;###autoload
(defun elpy-shell-send-defclass-and-step ()
  "Send the class definition that contains the current line to
the Python shell and steps.

See `elpy-shell--nav-beginning-of-def' for details."
  (interactive)
  (if (elpy-shell--nav-beginning-of-defclass)
      (elpy-shell-send-statement-and-step)
    (message "There is no class definition that includes the current line.")))

;;;###autoload
(defun elpy-shell-send-group-and-step ()
  "Send the current or next group of top-level statements to the Python shell and step.

A sequence of top-level statements is a group if they are not
separated by empty lines. Empty lines within each top-level
statement are ignored.

If the point is within a top-level statement, send the group
around this statement. Otherwise, go to the top-level statement
below point and send the group around this statement."
  (interactive)
  (elpy-shell--ensure-shell-running)
  (let* ((beg (progn (elpy-shell--nav-beginning-of-group) (point)))
         (end (progn
                ;; go forward to end of group
                (unless (python-info-current-line-comment-p)
                  (elpy-shell--nav-end-of-statement))
                (let ((p))
                  (while (not (eq p (point)))
                    (setq p (point))
                    (forward-line)
                    (if (elpy-shell--current-line-only-whitespace-p)
                        (goto-char p) ;; done
                      (unless (python-info-current-line-comment-p)
                        (elpy-shell--nav-end-of-statement)))))
                (point))))
    (if (> end beg)
        (progn
          (elpy-shell--flash-and-message-region beg end)
          ;; send the region and jump to next statement
          (if (string-match-p "\\`[^\n]*\\'" (buffer-substring beg end))
              ;; single line
              (elpy-shell-send-statement-and-step)
            ;; multiple lines
            (unless elpy-shell-echo-input
              (elpy-shell--append-to-shell-output "\n"))
            (elpy-shell--add-to-shell-history (buffer-substring beg end))
            (elpy-shell--with-maybe-echo
             (python-shell-send-string
              (python-shell-buffer-substring beg end)))
            (python-nav-forward-statement)))
      (goto-char (point-max)))
    (setq mark-active nil)))

;;;###autoload
(defun elpy-shell-send-codecell-and-step ()
  "Send the current code cell to the Python shell and step.

Signals an error if the point is not inside a code cell.

Cell beginnings and cell boundaries can be customized via the
variables `elpy-shell-cell-boundary-regexp' and
`elpy-shell-codecell-beginning-regexp', which see."
  (interactive)
  (let ((beg (save-excursion
               (end-of-line)
               (re-search-backward elpy-shell-cell-boundary-regexp nil t)
               (beginning-of-line)
               (and (string-match-p elpy-shell-codecell-beginning-regexp
                                    (thing-at-point 'line))
                    (point))))
        (end (save-excursion
               (forward-line)
               (if (re-search-forward elpy-shell-cell-boundary-regexp nil t)
                   (forward-line -1)
                 (goto-char (point-max)))
               (end-of-line)
               (point))))
    (if beg
        (progn
          (elpy-shell--flash-and-message-region beg end)
          (unless elpy-shell-echo-input
            (elpy-shell--append-to-shell-output "\n"))
          (elpy-shell--add-to-shell-history (buffer-substring beg end))
          (elpy-shell--with-maybe-echo
           (python-shell-send-string (python-shell-buffer-substring beg end)))
          (goto-char end)
          (python-nav-forward-statement))
      (message "Not in a codecell."))))

;;;###autoload
(defun elpy-shell-send-region-or-buffer-and-step (&optional arg)
  "Send the active region or the buffer to the Python shell and step.

If there is an active region, send that. Otherwise, send the
whole buffer.

In Emacs 24.3 and later, without prefix argument and when there
is no active region, this will escape the Python idiom of if
__name__ == '__main__' to be false to avoid accidental execution
of code. With prefix argument, this code is executed."
  (interactive "P")
  (if (use-region-p)
      (elpy-shell--flash-and-message-region (region-beginning) (region-end))
    (elpy-shell--flash-and-message-region (point-min) (point-max)))
  (elpy-shell--with-maybe-echo
   (elpy-shell--send-region-or-buffer-internal arg))
  (if (use-region-p)
      (goto-char (region-end))
    (goto-char (point-max))))

(defun elpy-shell--send-region-or-buffer-internal (&optional arg)
  "Send the active region or the buffer to the Python shell and step.

If there is an active region, send that. Otherwise, send the
whole buffer.

In Emacs 24.3 and later, without prefix argument and when there
is no active region, this will escape the Python idiom of if
__name__ == '__main__' to be false to avoid accidental execution
of code. With prefix argument, this code is executed."
  (interactive "P")
  (elpy-shell--ensure-shell-running)
  (unless elpy-shell-echo-input (elpy-shell--append-to-shell-output "\n"))
  (let ((if-main-regex "^if +__name__ +== +[\"']__main__[\"'] *:")
        (has-if-main-and-removed nil))
    (if (use-region-p)
        (let ((region (python-shell-buffer-substring
                       (region-beginning) (region-end)))
              (region-original (buffer-substring
                                (region-beginning) (region-end))))
          (when (string-match "\t" region)
            (message "Region contained tabs, this might cause weird errors"))
          ;; python-shell-buffer-substring (intentionally?) does not accurately
          ;; respect (region-beginning); it always start on the first character
          ;; of the respective line even if that's before the region beginning
          ;; Here we post-process the output to remove the characters before
          ;; (region-beginning) and the start of the line. The end of the region
          ;; is handled correctly and needs no special treatment.
          (let* ((bounds (save-excursion
                           (goto-char (region-beginning))
                           (bounds-of-thing-at-point 'line)))
                 (used-part (string-trim
                             (buffer-substring-no-properties
                              (car bounds)
                              (min (cdr bounds) (region-end)))))
                 (relevant-part (string-trim
                                 (buffer-substring-no-properties
                                  (max (car bounds) (region-beginning))
                                  (min (cdr bounds) (region-end))))))
            (setq region
                  ;; replace just first match
                  (replace-regexp-in-string
                   (concat "\\(" (regexp-quote used-part) "\\)\\(?:.*\n?\\)*\\'")
                   relevant-part
                   region t t 1))
            (elpy-shell--add-to-shell-history region-original)
            (python-shell-send-string region)))
      (unless arg
        (save-excursion
          (goto-char (point-min))
          (setq has-if-main-and-removed (re-search-forward if-main-regex nil t))))
      (python-shell-send-buffer arg))
    (when has-if-main-and-removed
      (message (concat "Removed if __name__ == '__main__' construct, "
                       "use a prefix argument to evaluate.")))))

;;;###autoload
(defun elpy-shell-send-buffer (&optional arg)
  "Send entire buffer to Pyton shell.

In Emacs 24.3 and later, without prefix argument, this will
escape the Python idiom of if __name__ == '__main__' to be false
to avoid accidental execution of code. With prefix argument, this
code is executed."
  (interactive "P")
  (save-mark-and-excursion
    (deactivate-mark)
    (elpy-shell-send-region-or-buffer-and-step arg)))

;;;###autoload
(defun elpy-shell-send-buffer-and-step (&optional arg)
  "Send entire buffer to Python shell.

In Emacs 24.3 and later, without prefix argument, this will
escape the Python idiom of if __name__ == '__main__' to be false
to avoid accidental execution of code. With prefix argument, this
code is executed."
  (interactive "P")
  (let ((p))
    (save-mark-and-excursion
      (deactivate-mark)
      (elpy-shell-send-region-or-buffer-and-step arg)
      (setq p (point)))
    (goto-char p)))

(defun elpy-shell--add-to-shell-history (string)
  "Add STRING to the shell command history."
  (when elpy-shell-add-to-shell-history
    (with-current-buffer (process-buffer (elpy-shell-get-or-create-process))
      (comint-add-to-input-history (string-trim string)))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Send command variations (with/without step; with/without go)

(defun elpy-shell--send-with-step-go (step-fun step go my-prefix-arg)
  "Run a function with STEP and/or GO.

STEP-FUN should be a function that sends something to the shell
and moves point to code position right after what has been sent.

When STEP is nil, keeps point position. When GO is non-nil,
switches focus to Python shell buffer."
  (let ((orig (point)))
    (setq current-prefix-arg my-prefix-arg)
    (call-interactively step-fun)
    (unless step
      (goto-char orig)))
  (when go
    (elpy-shell-switch-to-shell)))

(defmacro elpy-shell--defun-step-go (fun-and-step)
  "Defines fun, fun-and-go, fun-and-step-and-go for the given FUN-AND-STEP function."
  (let ((name (string-remove-suffix "-and-step" (symbol-name fun-and-step))))
    (list
     'progn
     (let ((fun (intern name)))
       `(defun ,fun (&optional arg)
          ,(concat "Run `" (symbol-name fun-and-step) "' but retain point position.")
          (interactive "P")
          (elpy-shell--send-with-step-go ',fun-and-step nil nil arg)))
     (let ((fun-and-go (intern (concat name "-and-go"))))
       `(defun ,fun-and-go (&optional arg)
          ,(concat "Run `" (symbol-name fun-and-step) "' but retain point position and switch to Python shell.")
          (interactive "P")
          (elpy-shell--send-with-step-go ',fun-and-step nil t arg)))
     (let ((fun-and-step-and-go (intern (concat name "-and-step-and-go"))))
       `(defun ,fun-and-step-and-go (&optional arg)
          ,(concat "Run `" (symbol-name fun-and-step) "' and switch to Python shell.")
          (interactive "P")
          (elpy-shell--send-with-step-go ',fun-and-step t t arg))))))

(elpy-shell--defun-step-go elpy-shell-send-statement-and-step)
(elpy-shell--defun-step-go elpy-shell-send-top-statement-and-step)
(elpy-shell--defun-step-go elpy-shell-send-defun-and-step)
(elpy-shell--defun-step-go elpy-shell-send-defclass-and-step)
(elpy-shell--defun-step-go elpy-shell-send-group-and-step)
(elpy-shell--defun-step-go elpy-shell-send-codecell-and-step)
(elpy-shell--defun-step-go elpy-shell-send-region-or-buffer-and-step)
(elpy-shell--defun-step-go elpy-shell-send-buffer-and-step)


;;;;;;;;;;;;;;;;;;;;;;;
;; Debugging features

(when (version<= "25" emacs-version)

  (defun elpy-pdb--refresh-breakpoints (lines)
    "Add new breakpoints at lines LINES of the current buffer."
    ;; Forget old breakpoints
    (python-shell-send-string-no-output "import bdb as __bdb; __bdb.Breakpoint.bplist={}; __bdb.Breakpoint.next=1;__bdb.Breakpoint.bpbynumber=[None]")
    (python-shell-send-string-no-output "import pdb; __pdbi = pdb.Pdb()")
    (dolist (line lines)
      (python-shell-send-string-no-output
       (format "__pdbi.set_break('''%s''', %s)" (buffer-file-name) line))))

  (defun elpy-pdb--start-pdb (&optional output)
    "Start pdb on the current script.

if OUTPUT is non-nil, display the prompt after execution."
    (let ((string (format "__pdbi._runscript('''%s''')" (buffer-file-name))))
      (if output
          (python-shell-send-string string)
        (python-shell-send-string-no-output string))))

  (defun elpy-pdb--get-breakpoint-positions ()
    "Return a list of lines with breakpoints."
    (let* ((overlays (overlay-lists))
           (overlays (append (car overlays) (cdr overlays)))
           (bp-lines '()))
      (dolist (ov overlays)
        (when (overlay-get ov 'elpy-breakpoint)
          (push (line-number-at-pos (overlay-start ov))
                bp-lines)))
      bp-lines))

  (defun elpy-pdb-debug-buffer (&optional arg)
    "Run pdb on the current buffer.

If breakpoints are set in the current buffer, jump to the first one.
If no breakpoints are set, debug from the beginning of the script.

With a prefix argument, ignore the existing breakpoints."
    (interactive "P")
    (if (not (buffer-file-name))
        (error "Debugging only work for buffers visiting a file")
      (elpy-shell--ensure-shell-running)
      (save-buffer)
      (let ((bp-lines (elpy-pdb--get-breakpoint-positions)))
        (if (or arg (= 0 (length bp-lines)))
            (progn
              (elpy-pdb--refresh-breakpoints '())
              (elpy-pdb--start-pdb t))
          (elpy-pdb--refresh-breakpoints bp-lines)
          (elpy-pdb--start-pdb)
          (python-shell-send-string "continue")))
      (elpy-shell-display-buffer)))

  (defun elpy-pdb-break-at-point ()
    "Run pdb on the current buffer and break at the current line.

Ignore the existing breakpoints.
Pdb can directly exit if the current line is not a statement
that is actually run (blank line, comment line, ...)."
    (interactive)
    (if (not (buffer-file-name))
        (error "Debugging only work for buffers visiting a file")
      (elpy-shell--ensure-shell-running)
      (save-buffer)
      (elpy-pdb--refresh-breakpoints (list (line-number-at-pos)))
      (elpy-pdb--start-pdb)
      (python-shell-send-string "continue")
      (elpy-shell-display-buffer)))

  (defun elpy-pdb-debug-last-exception ()
    "Run post-mortem pdb on the last exception."
    (interactive)
    (elpy-shell--ensure-shell-running)
    ;; check if there is a last exception
    (if (not (with-current-buffer (format "*%s*"
                                          (python-shell-get-process-name nil))
               (save-excursion
                 (goto-char (point-max))
                 (search-backward "Traceback (most recent call last):"
                                  nil t))))
        (error "No traceback on the current shell")
      (python-shell-send-string
       "import pdb as __pdb;__pdb.pm()"))
    (elpy-shell-display-buffer))

  ;; Fringe indicators

  (when (fboundp 'define-fringe-bitmap)
    (define-fringe-bitmap 'elpy-breakpoint-fringe-marker
      (vector
       #b00000000
       #b00111100
       #b01111110
       #b01111110
       #b01111110
       #b01111110
       #b00111100
       #b00000000)))

  (defcustom elpy-breakpoint-fringe-face 'elpy-breakpoint-fringe-face
    "Face for breakpoint bitmaps appearing on the fringe."
    :type 'face
    :group 'elpy)

  (defface elpy-breakpoint-fringe-face
    '((t (:foreground "red"
          :box (:line-width 1 :color "red" :style released-button))))
    "Face for breakpoint bitmaps appearing on the fringe."
    :group 'elpy)

  (defun elpy-pdb-toggle-breakpoint-at-point (&optional arg)
    "Add or remove a breakpoint at the current line.

With a prefix argument, remove all the breakpoints from the current
region or buffer."
    (interactive "P")
    (if arg
        (elpy-pdb-clear-breakpoints)
      (let ((overlays (overlays-in (line-beginning-position)
                                   (line-end-position)))
            bp-at-line)
        ;; Check if already a breakpoint
        (while overlays
          (let ((overlay (pop overlays)))
            (when (overlay-get overlay 'elpy-breakpoint)
              (setq bp-at-line t))))
        (if bp-at-line
            ;; If so, remove it
            (remove-overlays (line-beginning-position)
                             (line-end-position)
                             'elpy-breakpoint t)
          ;; Check it the line is empty
          (if (not (save-excursion
                     (beginning-of-line)
                     (looking-at "[[:space:]]*$")))
              ;; Else add a new breakpoint
              (let* ((ov (make-overlay (line-beginning-position)
                                       (+ 1 (line-beginning-position))))
                     (marker-string "*fringe-dummy*")
                     (marker-length (length marker-string)))
                (put-text-property 0 marker-length
                                   'display
                                   (list 'left-fringe
                                         'elpy-breakpoint-fringe-marker
                                         'elpy-breakpoint-fringe-face)
                                   marker-string)
                (overlay-put ov 'before-string marker-string)
                (overlay-put ov 'priority 200)
                (overlay-put ov 'elpy-breakpoint t)))))))

  (defun elpy-pdb-clear-breakpoints ()
    "Remove the breakpoints in the current region or buffer."
    (if (use-region-p)
        (remove-overlays (region-beginning) (region-end) 'elpy-breakpoint t)
      (remove-overlays (point-min) (point-max) 'elpy-breakpoint t))))


(provide 'elpy-shell)
;;; elpy-shell.el ends here
