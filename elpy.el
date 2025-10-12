;;; elpy.el --- Emacs Python Development Environment -*- lexical-binding: t -*-

;; Copyright (C) 2012-2019  Jorgen Schaefer

;; Author: Jorgen Schaefer <contact@jorgenschaefer.de>, Gaby Launay <gaby.launay@protonmail.com>
;; URL: https://github.com/jorgenschaefer/elpy

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Ports interactive Python support from elpy

;;; Code:

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
;;; elpy.el ends here
