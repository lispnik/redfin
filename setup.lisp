;;;; setup.lisp --- load ocicl-managed systems for this project
;;;;
;;;; ocicl writes a per-project setup file (usually ~/.local/share/ocicl or a
;;;; local systems/ dir). This shim tries the local project setup first, then
;;;; falls back to the user-global ocicl runtime, so `sbcl --load setup.lisp`
;;;; makes (asdf:load-system :redfin) work from a clean image.

(require :asdf)

(let ((local (merge-pathnames "systems/setup.lisp" *load-truename*))
      (global (merge-pathnames ".local/share/ocicl/ocicl-runtime.lisp"
                               (user-homedir-pathname))))
  (cond
    ((probe-file local) (load local))
    ((probe-file global) (load global))
    (t (format *error-output*
               "~&No ocicl setup found. Run `ocicl install` in the repo root ~
                first.~%"))))

;; Make this project's .asd discoverable regardless of where SBCL was started.
(pushnew (truename (directory-namestring *load-truename*))
         asdf:*central-registry* :test #'equal)
