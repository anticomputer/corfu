;;; corfu.el --- Completion Overlay Region FUnction -*- lexical-binding: t -*-

;; Copyright (C) 2021  Free Software Foundation, Inc.

;; Author: Daniel Mendler <mail@daniel-mendler.de>
;; Maintainer: Daniel Mendler <mail@daniel-mendler.de>
;; Created: 2021
;; Version: 0.16
;; Package-Requires: ((emacs "27.1"))
;; Homepage: https://github.com/minad/corfu

;; This file is part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Corfu enhances the default completion in region function with a
;; completion overlay. The current candidates are shown in a popup
;; below or above the point. Corfu can be considered the minimalistic
;; completion-in-region counterpart of Vertico.

;;; Code:

(require 'seq)
(eval-when-compile
  (require 'cl-lib)
  (require 'subr-x))

(defgroup corfu nil
  "Completion Overlay Region FUnction."
  :group 'convenience
  :prefix "corfu-")

(defcustom corfu-count 10
  "Maximal number of candidates to show."
  :type 'integer)

(defcustom corfu-scroll-margin 2
  "Number of lines at the top and bottom when scrolling.
The value should lie between 0 and corfu-count/2."
  :type 'integer)

(defcustom corfu-min-width 15
  "Popup minimum width in characters."
  :type 'integer)

(defcustom corfu-max-width 100
  "Popup maximum width in characters."
  :type 'integer)

(defcustom corfu-cycle nil
  "Enable cycling for `corfu-next' and `corfu-previous'."
  :type 'boolean)

(defcustom corfu-continue-commands
  ;; nil is undefined command
  '(nil ignore completion-at-point universal-argument universal-argument-more digit-argument
        "\\`corfu-" "\\`scroll-other-window")
  "Continue Corfu completion after executing these commands."
  :type '(repeat (choice regexp symbol)))

(defcustom corfu-commit-predicate #'corfu-candidate-previewed-p
  "Automatically commit if the predicate returns t."
  :type '(choice (const nil) function))

(defcustom corfu-preview-current t
  "Preview currently selected candidate."
  :type 'boolean)

(defcustom corfu-preselect-first t
  "Preselect first candidate."
  :type 'boolean)

(defcustom corfu-quit-at-boundary nil
  "Automatically quit at completion field/word boundary.
If automatic quitting is disabled, Orderless filter strings with spaces
are allowed."
  :type 'boolean)

(defcustom corfu-quit-no-match 1.0
  "Automatically quit if no matching candidate is found.
If a floating point number, quit on no match only if the auto-started
completion began less than that number of seconds ago."
  :type '(choice boolean float))

(defcustom corfu-excluded-modes nil
  "List of modes excluded by `corfu-global-mode'."
  :type '(repeat symbol))

(defcustom corfu-left-margin-width 0.5
  "Width of the left margin in units of the character width."
  :type 'float)

(defcustom corfu-right-margin-width 0.5
  "Width of the right margin in units of the character width."
  :type 'float)

(defcustom corfu-bar-width 0.2
  "Width of the bar in units of the character width."
  :type 'float)

(defcustom corfu-echo-documentation 0.5
  "Show documentation string in the echo area after that number of seconds."
  :type '(choice boolean float))

(defcustom corfu-margin-formatters nil
  "Registry for margin formatter functions.
Each function of the list is called with the completion metadata as
argument until an appropriate formatter is found. The function should
return a formatter function, which takes the candidate string and must
return a string, possibly an icon."
  :type 'hook)

(defcustom corfu-sort-function #'corfu-sort-length-alpha
  "Default sorting function, used if no `display-sort-function' is specified."
  :type `(choice
          (const :tag "No sorting" nil)
          (const :tag "By length and alpha" ,#'corfu-sort-length-alpha)
          (function :tag "Custom function")))

(defcustom corfu-auto-prefix 3
  "Minimum length of prefix for auto completion.
The completion backend can override this with
:company-prefix-length."
  :type 'integer)

(defcustom corfu-auto-delay 0.2
  "Delay for auto completion."
  :type 'float)

(defcustom corfu-auto-commands
  '("self-insert-command\\'"
    c-electric-colon c-electric-lt-gt c-electric-slash c-scope-operator)
  "Commands which initiate auto completion."
  :type '(repeat (choice regexp symbol)))

(defcustom corfu-auto nil
  "Enable auto completion."
  :type 'boolean)

(defgroup corfu-faces nil
  "Faces used by Corfu."
  :group 'corfu
  :group 'faces)

(defface corfu-default
  '((((class color) (min-colors 88) (background dark)) :background "#191a1b")
    (((class color) (min-colors 88) (background light)) :background "#f0f0f0")
    (t :background "gray"))
  "Default face used for the popup, in particular the background and foreground color.")

(defface corfu-current
  '((((class color) (min-colors 88) (background dark))
     :background "#00415e" :foreground "white")
    (((class color) (min-colors 88) (background light))
     :background "#c0efff" :foreground "black")
    (t :background "blue" :foreground "white"))
  "Face used to highlight the currently selected candidate.")

(defface corfu-bar
  '((((class color) (min-colors 88) (background dark)) :background "#a8a8a8")
    (((class color) (min-colors 88) (background light)) :background "#505050")
    (t :background "gray"))
  "The background color is used for the scrollbar indicator.")

(defface corfu-border
  '((((class color) (min-colors 88) (background dark)) :background "#323232")
    (((class color) (min-colors 88) (background light)) :background "#d7d7d7")
    (t :background "gray"))
  "The background color used for the thin border.")

(defface corfu-echo
  '((t :inherit completions-annotations))
  "Face used for echo area messages.")

(defface corfu-annotations
  '((t :inherit completions-annotations))
  "Face used for annotations.")

(defface corfu-deprecated
  '((t :inherit shadow :strike-through t))
  "Face used for deprecated candidates.")

(defvar corfu-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap beginning-of-buffer] #'corfu-first)
    (define-key map [remap end-of-buffer] #'corfu-last)
    (define-key map [remap scroll-down-command] #'corfu-scroll-down)
    (define-key map [remap scroll-up-command] #'corfu-scroll-up)
    (define-key map [remap next-line] #'corfu-next)
    (define-key map [remap previous-line] #'corfu-previous)
    (define-key map [remap completion-at-point] #'corfu-complete)
    (define-key map [down] #'corfu-next)
    (define-key map [up] #'corfu-previous)
    (define-key map [remap keyboard-escape-quit] #'corfu-reset)
    ;; XXX [tab] is bound because of org-mode
    ;; The binding should be removed from org-mode-map.
    (define-key map [tab] #'corfu-complete)
    (define-key map "\en" #'corfu-next)
    (define-key map "\ep" #'corfu-previous)
    (define-key map "\C-g" #'corfu-quit)
    (define-key map "\r" #'corfu-insert)
    (define-key map "\t" #'corfu-complete)
    (define-key map "\eg" #'corfu-show-location)
    (define-key map "\eh" #'corfu-show-documentation)
    map)
  "Corfu keymap used when popup is shown.")

(defvar corfu--auto-timer nil
  "Auto completion timer.")

(defvar-local corfu--candidates nil
  "List of candidates.")

(defvar-local corfu--metadata nil
  "Completion metadata.")

(defvar-local corfu--base 0
  "Size of the base string, which is concatenated with the candidate.")

(defvar-local corfu--total 0
  "Length of the candidate list `corfu--candidates'.")

(defvar-local corfu--highlight #'identity
  "Deferred candidate highlighting function.")

(defvar-local corfu--index -1
  "Index of current candidate or negative for prompt selection.")

(defvar-local corfu--preselect -1
  "Index of preselected candidate, negative for prompt selection.")

(defvar-local corfu--scroll 0
  "Scroll position.")

(defvar-local corfu--input nil
  "Cons of last prompt contents and point or t.")

(defvar-local corfu--preview-ov nil
  "Current candidate overlay.")

(defvar-local corfu--extra nil
  "Extra completion properties.")

(defvar-local corfu--change-group nil
  "Undo change group.")

(defvar-local corfu--auto-start nil
  "Auto completion start time.")

(defvar-local corfu--echo-timer nil
  "Echo area message timer.")

(defvar-local corfu--echo-message nil
  "Last echo message.")

(defvar corfu--frame nil
  "Popup frame.")

(defconst corfu--state-vars
  '(corfu--base
    corfu--candidates
    corfu--highlight
    corfu--index
    corfu--preselect
    corfu--scroll
    corfu--input
    corfu--total
    corfu--preview-ov
    corfu--extra
    corfu--auto-start
    corfu--echo-timer
    corfu--echo-message
    corfu--change-group
    corfu--metadata)
  "Buffer-local state variables used by Corfu.")

(defvar corfu--frame-parameters
  '((no-accept-focus . t)
    (no-focus-on-map . t)
    (min-width . t)
    (min-height . t)
    (width . 0)
    (height . 0)
    (border-width . 0)
    (child-frame-border-width . 1)
    (left-fringe . 0)
    (right-fringe . 0)
    (vertical-scroll-bars . nil)
    (horizontal-scroll-bars . nil)
    (menu-bar-lines . 0)
    (tool-bar-lines . 0)
    (tab-bar-lines . 0)
    (no-other-frame . t)
    (no-other-window . t)
    (no-delete-other-windows . t)
    (unsplittable . t)
    (undecorated . t)
    (cursor-type . nil)
    (visibility . nil)
    (no-special-glyphs . t)
    (desktop-dont-save . t))
  "Default child frame parameters.")

(defvar corfu--buffer-parameters
  '((mode-line-format . nil)
    (header-line-format . nil)
    (tab-line-format . nil)
    (tab-bar-format . nil) ;; Emacs 28 tab-bar-format
    (frame-title-format . "")
    (truncate-lines . t)
    (cursor-in-non-selected-windows . nil)
    (cursor-type . nil)
    (show-trailing-whitespace . nil)
    (display-line-numbers . nil)
    (left-fringe-width . nil)
    (right-fringe-width . nil)
    (left-margin-width . 0)
    (right-margin-width . 0)
    (fringes-outside-margins . 0)
    (buffer-read-only . t))
  "Default child frame buffer parameters.")

(defvar corfu--mouse-ignore-map
  (let ((map (make-sparse-keymap)))
    (dotimes (i 7)
      (dolist (k '(mouse down-mouse drag-mouse double-mouse triple-mouse))
        (define-key map (vector (intern (format "%s-%s" k (1+ i)))) #'ignore)))
    map)
  "Ignore all mouse clicks.")

(defun corfu--popup-redirect-focus ()
  "Redirect focus from popup."
  (redirect-frame-focus corfu--frame (frame-parent corfu--frame)))

(defun corfu--make-buffer (content)
  "Create corfu buffer with CONTENT."
  (let ((fr face-remapping-alist)
        (buffer (get-buffer-create " *corfu*")))
    (with-current-buffer buffer
      ;;; XXX HACK install redirect focus hook
      (add-hook 'pre-command-hook #'corfu--popup-redirect-focus nil 'local)
      ;;; XXX HACK install mouse ignore map
      (use-local-map corfu--mouse-ignore-map)
      (dolist (var corfu--buffer-parameters)
        (set (make-local-variable (car var)) (cdr var)))
      (setq-local face-remapping-alist (copy-tree fr))
      (cl-pushnew 'corfu-default (alist-get 'default face-remapping-alist))
      (let ((inhibit-modification-hooks t)
            (inhibit-read-only t))
        (erase-buffer)
        (insert content)
        (goto-char (point-min))))
    buffer))

;; Function adapted from posframe.el by tumashu
(defun corfu--make-frame (x y width height content)
  "Show child frame at X/Y with WIDTH/HEIGHT and CONTENT."
  (let* ((window-min-height 1)
         (window-min-width 1)
         (x-gtk-resize-child-frames
          (let ((case-fold-search t))
            (and
             ;; XXX HACK to fix resizing on gtk3/gnome taken from posframe.el
             ;; More information:
             ;; * https://github.com/minad/corfu/issues/17
             ;; * https://gitlab.gnome.org/GNOME/mutter/-/issues/840
             ;; * https://lists.gnu.org/archive/html/emacs-devel/2020-02/msg00001.html
             (string-match-p "gtk3" system-configuration-features)
             (string-match-p "gnome\\|cinnamon" (or (getenv "XDG_CURRENT_DESKTOP")
                                                    (getenv "DESKTOP_SESSION") ""))
             'resize-mode)))
         (after-make-frame-functions)
         (edge (window-inside-pixel-edges))
         (lh (default-line-height))
         (x (max 0 (min (+ (car edge) x
                           (- (alist-get 'child-frame-border-width corfu--frame-parameters)))
                        (- (frame-pixel-width) width))))
         (yb (+ (cadr edge) (window-tab-line-height) y lh))
         (y (if (> (+ yb height lh lh) (frame-pixel-height))
                (- yb height lh 1)
              yb))
         (buffer (corfu--make-buffer content)))
    (unless (and (frame-live-p corfu--frame)
                 (eq (frame-parent corfu--frame) (window-frame)))
      (when corfu--frame (delete-frame corfu--frame))
      (setq corfu--frame (make-frame
                          `((parent-frame . ,(window-frame))
                            (minibuffer . ,(minibuffer-window (window-frame)))
                            (line-spacing . ,line-spacing)
                            ;; Set `internal-border-width' for Emacs 27
                            (internal-border-width
                             . ,(alist-get 'child-frame-border-width corfu--frame-parameters))
                            ,@corfu--frame-parameters))))
    ;; XXX HACK Setting the same frame-parameter/face-background is not a nop (BUG!).
    ;; Check explicitly before applying the setting.
    ;; Without the check, the frame flickers on Mac.
    ;; XXX HACK We have to apply the face background before adjusting the frame parameter,
    ;; otherwise the border is not updated (BUG!).
    (let* ((face (if (facep 'child-frame-border) 'child-frame-border 'internal-border))
	   (new (face-attribute 'corfu-border :background nil 'default)))
      (unless (equal (face-attribute face :background corfu--frame 'default) new)
	(set-face-background face new corfu--frame)))
    (let ((new (face-attribute 'corfu-default :background nil 'default)))
      (unless (equal (frame-parameter corfu--frame 'background-color) new)
	(set-frame-parameter corfu--frame 'background-color new)))
    (let ((win (frame-root-window corfu--frame)))
      (set-window-buffer win buffer)
      ;; Mark window as dedicated to prevent frame reuse (#60)
      (set-window-dedicated-p win t))
    ;; XXX HACK Make the frame invisible before moving the popup in order to avoid flicker.
    (unless (eq (cdr (frame-position corfu--frame)) y)
      (make-frame-invisible corfu--frame))
    (set-frame-position corfu--frame x y)
    (set-frame-size corfu--frame width height t)
    (make-frame-visible corfu--frame)))

(defun corfu--popup-show (pos off width lines &optional curr lo bar)
  "Show LINES as popup at POS - OFF.
WIDTH is the width of the popup.
The current candidate CURR is highlighted.
A scroll bar is displayed from LO to LO+BAR."
  (let* ((ch (default-line-height))
         (cw (default-font-width))
         (lm (ceiling (* cw corfu-left-margin-width)))
         (rm (ceiling (* cw corfu-right-margin-width)))
         (bw (ceiling (min rm (* cw corfu-bar-width))))
         (lmargin (and (> lm 0) (propertize " " 'display `(space :width (,lm)))))
         (rmargin (and (> rm 0) (propertize " " 'display `(space :align-to right))))
         (sbar (when (> bw 0)
                 (concat (propertize " " 'display `(space :align-to (- right (,rm))))
                         (propertize " " 'display `(space :width (,(- rm bw))))
                         (propertize " " 'face 'corfu-bar 'display `(space :width (,bw))))))
         (row 0)
         (pos (posn-x-y (posn-at-point pos)))
         (x (or (car pos) 0))
         (y (or (cdr pos) 0)))
    (corfu--make-frame
     (- x lm (* cw off)) y
     (+ (* width cw) lm rm) (* (length lines) ch)
     (mapconcat (lambda (line)
                  (let ((str (concat lmargin line
                                     (if (and lo (<= lo row (+ lo bar))) sbar rmargin))))
                    (when (eq row curr)
                      (add-face-text-property
                       0 (length str) 'corfu-current 'append str))
                    (setq row (1+ row))
                    str))
                lines "\n"))))

(defun corfu--popup-hide ()
  "Hide Corfu popup."
  (when (frame-live-p corfu--frame)
    (make-frame-invisible corfu--frame)
    (with-current-buffer (window-buffer (frame-root-window corfu--frame))
      (let ((inhibit-read-only t))
        (erase-buffer)))))

(defun corfu--move-to-front (elem list)
  "Move ELEM to front of LIST."
  (if-let (found (member elem list))
      (let ((head (list (car found))))
        (nconc head (delq (setcar found nil) list)))
    list))

;; bug#47711: Deferred highlighting for `completion-all-completions'
;; XXX There is one complication: `completion--twq-all' already adds `completions-common-part'.
(defun corfu--all-completions (&rest args)
  "Compute all completions for ARGS with deferred highlighting."
  (cl-letf* ((orig-pcm (symbol-function #'completion-pcm--hilit-commonality))
             (orig-flex (symbol-function #'completion-flex-all-completions))
             ((symbol-function #'completion-flex-all-completions)
              (lambda (&rest args)
                ;; Unfortunately for flex we have to undo the deferred highlighting, since flex uses
                ;; the completion-score for sorting, which is applied during highlighting.
                (cl-letf (((symbol-function #'completion-pcm--hilit-commonality) orig-pcm))
                  (apply orig-flex args))))
             ;; Defer the following highlighting functions
             (hl #'identity)
             ((symbol-function #'completion-hilit-commonality)
              (lambda (cands prefix &optional base)
                (setq hl (lambda (x) (nconc (completion-hilit-commonality x prefix base) nil)))
                (and cands (nconc cands base))))
             ((symbol-function #'completion-pcm--hilit-commonality)
              (lambda (pattern cands)
                (setq hl (lambda (x)
                           ;; `completion-pcm--hilit-commonality' sometimes throws an internal error
                           ;; for example when entering "/sudo:://u".
                           (condition-case nil
                               (completion-pcm--hilit-commonality pattern x)
                             (t x))))
                cands)))
    ;; Only advise orderless after it has been loaded to avoid load order issues
    (if (and (fboundp 'orderless-highlight-matches) (fboundp 'orderless-pattern-compiler))
        (cl-letf (((symbol-function 'orderless-highlight-matches)
                   (lambda (pattern cands)
                     (let ((regexps (orderless-pattern-compiler pattern)))
                       (setq hl (lambda (x) (orderless-highlight-matches regexps x))))
                     cands)))
          (cons (apply #'completion-all-completions args) hl))
      (cons (apply #'completion-all-completions args) hl))))

(defun corfu--sort-predicate (x y)
  "Sorting predicate which compares X and Y."
  (or (< (length x) (length y)) (and (= (length x) (length y)) (string< x y))))

(defun corfu-sort-length-alpha (list)
  "Sort LIST by length and alphabetically."
  (sort list #'corfu--sort-predicate))

(defmacro corfu--partition! (list form)
  "Evaluate FORM for every element and partition LIST."
  (let ((head1 (make-symbol "head1"))
        (head2 (make-symbol "head2"))
        (tail1 (make-symbol "tail1"))
        (tail2 (make-symbol "tail2")))
    `(let* ((,head1 (cons nil nil))
            (,head2 (cons nil nil))
            (,tail1 ,head1)
            (,tail2 ,head2))
       (while ,list
         (if (let ((it (car ,list))) ,form)
             (progn
               (setcdr ,tail1 ,list)
               (pop ,tail1))
           (setcdr ,tail2 ,list)
           (pop ,tail2))
         (pop ,list))
       (setcdr ,tail1 (cdr ,head2))
       (setcdr ,tail2 nil)
       (setq ,list (cdr ,head1)))))

(defun corfu--move-prefix-candidates-to-front (field candidates)
  "Move CANDIDATES which match prefix of FIELD to the beginning."
  (let* ((word (replace-regexp-in-string " .*" "" field))
         (len (length word)))
    (corfu--partition! candidates
                       (and (>= (length it) len)
                            (eq t (compare-strings word 0 len it 0 len))))))

(defun corfu--filter-files (files)
  "Filter FILES by `completion-ignored-extensions'."
  (let ((re (concat "\\(?:\\(?:\\`\\|/\\)\\.\\.?/\\|"
                    (regexp-opt completion-ignored-extensions)
                    "\\)\\'")))
    (or (seq-remove (lambda (x) (string-match-p re x)) files) files)))

(defun corfu--sort-function ()
  "Return the sorting function."
  (or (corfu--metadata-get 'display-sort-function) corfu-sort-function))

(defun corfu--recompute-candidates (str pt table pred)
  "Recompute candidates from STR, PT, TABLE and PRED."
  (pcase-let* ((before (substring str 0 pt))
               (after (substring str pt))
               (corfu--metadata (completion-metadata before table pred))
               ;; bug#47678: `completion-boundaries` fails for `partial-completion`
               ;; if the cursor is moved between the slashes of "~//".
               ;; See also vertico.el which has the same issue.
               (bounds (or (condition-case nil
                               (completion-boundaries before table pred after)
                             (t (cons 0 (length after))))))
               (field (substring str (car bounds) (+ pt (cdr bounds))))
               (completing-file (eq (corfu--metadata-get 'category) 'file))
               (`(,all . ,hl) (corfu--all-completions str table pred pt corfu--metadata))
               (base (or (when-let (z (last all)) (prog1 (cdr z) (setcdr z nil))) 0)))
    ;; Filter the ignored file extensions. We cannot use modified predicate for this filtering,
    ;; since this breaks the special casing in the `completion-file-name-table' for `file-exists-p'
    ;; and `file-directory-p'.
    (when completing-file (setq all (corfu--filter-files all)))
    (setq all (delete-consecutive-dups (funcall (or (corfu--sort-function) #'identity) all)))
    (setq all (corfu--move-prefix-candidates-to-front field all))
    (when (and completing-file (not (string-suffix-p "/" field)))
      (setq all (corfu--move-to-front (concat field "/") all)))
    (setq all (corfu--move-to-front field all))
    (list base all (length all) hl corfu--metadata
          ;; Select the prompt when the input is a valid completion
          ;; and if it is not equal to the first candidate.
          (if (or (not corfu-preselect-first) (not all)
                  (and (not (equal field (car all)))
                       (not (and completing-file (equal (concat field "/") (car all))))
                       (test-completion str table pred)))
              -1 0))))

(defun corfu--update-candidates (str pt table pred)
  "Update candidates from STR, PT, TABLE and PRED."
  ;; Redisplay such that the input becomes immediately visible before the
  ;; expensive candidate recomputation is performed (Issue #48). See also
  ;; corresponding vertico#89.
  (redisplay)
  (pcase (while-no-input (corfu--recompute-candidates str pt table pred))
    ('nil (keyboard-quit))
    (`(,base ,candidates ,total ,hl ,metadata ,preselect)
     (setq corfu--input (cons str pt)
           corfu--candidates candidates
           corfu--base base
           corfu--total total
           corfu--preselect preselect
           corfu--index preselect
           corfu--highlight hl
           corfu--metadata metadata))))

(defun corfu--match-symbol-p (pattern sym)
  "Return non-nil if SYM is matching an element of the PATTERN list."
  (and (symbolp sym)
       (cl-loop for x in pattern
                thereis (if (symbolp x)
                            (eq sym x)
                          (string-match-p x (symbol-name sym))))))

(defun corfu-quit ()
  "Quit Corfu completion."
  (interactive)
  (completion-in-region-mode -1))

(defun corfu-reset ()
  "Reset Corfu completion.
This command can be executed multiple times by hammering the ESC key. If a
candidate is selected, unselect the candidate. Otherwise reset the input. If
there hasn't been any input, then quit."
  (interactive)
  (if (/= corfu--index corfu--preselect)
      (progn
        (corfu--goto -1)
        (setq this-command #'corfu-first))
    ;; Cancel all changes and start new change group.
    (cancel-change-group corfu--change-group)
    (activate-change-group (setq corfu--change-group (prepare-change-group)))
    (when (eq last-command #'corfu-reset) (corfu-quit))))

(defun corfu--affixate (cands)
  "Annotate CANDS with annotation function."
  (setq cands
        (if-let (aff (or (corfu--metadata-get 'affixation-function)
                         (plist-get corfu--extra :affixation-function)))
            (funcall aff cands)
          (if-let (ann (or (corfu--metadata-get 'annotation-function)
                           (plist-get corfu--extra :annotation-function)))
              (cl-loop for cand in cands collect
                       (let ((suffix (or (funcall ann cand) "")))
                         (list cand ""
                               ;; The default completion UI adds the `completions-annotations' face
                               ;; if no other faces are present. We use a custom `corfu-annotations'
                               ;; face to allow further styling which fits better for popups.
                               (if (text-property-not-all 0 (length suffix) 'face nil suffix)
                                   suffix
                                 (propertize suffix 'face 'corfu-annotations)))))
            (cl-loop for cand in cands collect (list cand "" "")))))
  (let* ((dep (plist-get corfu--extra :company-deprecated))
         (completion-extra-properties corfu--extra)
         (mf (run-hook-with-args-until-success 'corfu-margin-formatters corfu--metadata)))
    (cl-loop for x in cands for (c . _) = x do
             (when mf
               (setf (cadr x) (funcall mf c)))
             (when (and dep (funcall dep c))
               (setcar x (setq c (substring c)))
               (add-face-text-property 0 (length c) 'corfu-deprecated 'append c)))
    (cons mf cands)))

(defun corfu--metadata-get (prop)
  "Return PROP from completion metadata."
  ;; Note: Do not use `completion-metadata-get' in order to avoid Marginalia.
  ;; The Marginalia annotators are too heavy for the Corfu popup!
  (cdr (assq prop corfu--metadata)))

(defun corfu--format-candidates (cands)
  "Format annotated CANDS."
  (setq cands
        (cl-loop for c in cands collect
                 (cl-loop for s in c collect
                          (replace-regexp-in-string "[ \t]*\n[ \t]*" " " s))))
  (let* ((cw (cl-loop for x in cands maximize (string-width (car x))))
         (pw (cl-loop for x in cands maximize (string-width (cadr x))))
         (sw (cl-loop for x in cands maximize (string-width (caddr x))))
         (width (+ pw cw sw)))
    (when (< width corfu-min-width)
      (setq cw (+ cw (- corfu-min-width width))
            width corfu-min-width))
    ;; -4 because of margins and some additional safety
    (setq width (min width corfu-max-width (- (frame-width) 4)))
    (list pw width
          (cl-loop for (cand prefix suffix) in cands collect
                   (truncate-string-to-width
                    (concat prefix
                            (make-string (- pw (string-width prefix)) ?\s)
                            cand
                            (when (/= sw 0)
                              (make-string (+ (- cw (string-width cand))
                                              (- sw (string-width suffix)))
                                           ?\s))
                            suffix)
                    width)))))

(defun corfu--update-scroll ()
  "Update scroll position."
  (let ((off (max (min corfu-scroll-margin (/ corfu-count 2)) 0))
        (corr (if (= corfu-scroll-margin (/ corfu-count 2)) (1- (mod corfu-count 2)) 0)))
    (setq corfu--scroll (min (max 0 (- corfu--total corfu-count))
                             (max 0 (+ corfu--index off 1 (- corfu-count))
                                  (min (- corfu--index off corr) corfu--scroll))))))

(defun corfu--candidates-popup (pos)
  "Show candidates popup at POS."
  (corfu--update-scroll)
  (pcase-let* ((last (min (+ corfu--scroll corfu-count) corfu--total))
               (bar (ceiling (* corfu-count corfu-count) corfu--total))
               (lo (min (- corfu-count bar 1) (floor (* corfu-count corfu--scroll) corfu--total)))
               (`(,mf . ,acands) (corfu--affixate (funcall corfu--highlight
                                   (seq-subseq corfu--candidates corfu--scroll last))))
               (`(,pw ,width ,fcands) (corfu--format-candidates acands))
               ;; Disable the left margin if a margin formatter is active.
               (corfu-left-margin-width (if mf 0 corfu-left-margin-width)))
    ;; Nonlinearity at the end and the beginning
    (when (/= corfu--scroll 0)
      (setq lo (max 1 lo)))
    (when (/= last corfu--total)
      (setq lo (min (- corfu-count bar 2) lo)))
    (corfu--popup-show (+ pos corfu--base) pw width fcands (- corfu--index corfu--scroll)
                       (and (> corfu--total corfu-count) lo) bar)))

(defun corfu--preview-current (beg end str)
  "Show current candidate as overlay given BEG, END and STR."
  (when-let (cand (and corfu-preview-current (>= corfu--index 0)
                       (/= corfu--index corfu--preselect)
                       (nth corfu--index corfu--candidates)))
    (setq corfu--preview-ov (make-overlay beg end nil t t))
    (overlay-put corfu--preview-ov 'priority 1000)
    (overlay-put corfu--preview-ov 'window (selected-window))
    (overlay-put corfu--preview-ov
                 (if (= beg end) 'after-string 'display)
                 (concat (substring str 0 corfu--base) cand))))

(defun corfu--echo-refresh ()
  "Refresh echo message to prevent flicker during redisplay."
  (when corfu--echo-timer
    (cancel-timer corfu--echo-timer)
    (setq corfu--echo-timer nil))
  (when corfu--echo-message
    (corfu--echo-show corfu--echo-message)))

(defun corfu--echo-show (msg)
  "Show MSG in echo area."
  (let ((message-log-max nil))
    (setq corfu--echo-message msg)
    (message "%s" (if (text-property-not-all 0 (length msg) 'face nil msg)
                      msg
                    (propertize msg 'face 'corfu-echo)))))

(defun corfu--echo-documentation ()
  "Show documentation string of current candidate in echo area."
  (when corfu-echo-documentation
    (if-let* ((fun (plist-get corfu--extra :company-docsig))
              (cand (and (>= corfu--index 0) (nth corfu--index corfu--candidates)))
              (doc (funcall fun cand)))
        (if (or (eq corfu-echo-documentation t) corfu--echo-message)
            (corfu--echo-show doc)
          (setq corfu--echo-timer (run-with-idle-timer corfu-echo-documentation
                                                       nil #'corfu--echo-show doc)))
      (when corfu--echo-message
        (corfu--echo-show "")))))

(defun corfu--update ()
  "Refresh Corfu UI."
  (pcase-let* ((`(,beg ,end ,table ,pred) completion-in-region--data)
               (pt (- (point) beg))
               (str (buffer-substring-no-properties beg end))
               (initializing (not corfu--input))
               (continue (or (/= beg end)
                             (corfu--match-symbol-p corfu-continue-commands
                                                    this-command))))
    (corfu--echo-refresh)
    (cond
     ;; XXX Guard against errors during candidate generation.
     ;; Turn off completion immediately if there are errors
     ;; For example dabbrev throws error "No dynamic expansion ... found".
     ;; TODO Report this as a bug? Are completion tables supposed to throw errors?
     ((condition-case err
          ;; Only recompute when input changed and when input is non-empty
          (when (and continue (not (equal corfu--input (cons str pt))))
            (corfu--update-candidates str pt table pred)
            nil)
        (error (corfu-quit)
               (message "Corfu completion error: %s" (error-message-string err)))))
     ;; 1) Initializing, no candidates => Quit
     ((and initializing (not corfu--candidates))
      (corfu-quit))
     ;; 2) Single matching candidate and no further completion is possible
     ((and (not (equal str ""))
           (equal corfu--candidates (list str))
           (not (consp (completion-try-completion str table pred pt corfu--metadata))))
      (corfu--done str (if initializing 'exact 'finished)))
     ;; 3) There exist candidates
     ;; &  Input is non-empty or continue command
     ;; => Show candidates popup
     ((and corfu--candidates continue)
      (corfu--candidates-popup beg)
      (corfu--echo-documentation)
      (corfu--preview-current beg end str))
     ;; 4) There are no candidates & corfu-quit-no-match => Confirmation popup
     ((not (or corfu--candidates
               ;; When `corfu-quit-no-match' is a number of seconds and the auto completion wasn't
               ;; initiated too long ago, quit directly without showing the "No match" popup.
               (if (and corfu--auto-start (numberp corfu-quit-no-match))
                   (< (- (float-time) corfu--auto-start) corfu-quit-no-match)
                 (eq t corfu-quit-no-match))))
      (corfu--popup-show beg 0 8 '(#("No match" 0 8 (face italic)))))
     (t (corfu-quit)))))

(defun corfu--pre-command ()
  "Insert selected candidate unless command is marked to continue completion."
  (add-hook 'window-configuration-change-hook #'corfu-quit)
  (when corfu--preview-ov
    (delete-overlay corfu--preview-ov)
    (setq corfu--preview-ov nil))
  (when (and corfu-commit-predicate
             (not (corfu--match-symbol-p corfu-continue-commands this-command))
             (funcall corfu-commit-predicate))
    (corfu--insert 'exact)))

(defun corfu-candidate-previewed-p ()
  "Return t if a candidate is selected and previewed."
  (and corfu-preview-current (/= corfu--index corfu--preselect)))

(defun corfu--post-command ()
  "Refresh Corfu after last command."
  (remove-hook 'window-configuration-change-hook #'corfu-quit)
  (or (pcase completion-in-region--data
        (`(,beg ,end . ,_)
         (when (let ((pt (point)))
                 (and (eq (marker-buffer beg) (current-buffer))
                      (<= beg pt end)
                      (save-excursion
                        (goto-char beg)
                        (<= (line-beginning-position) pt (line-end-position)))
                      (or (not corfu-quit-at-boundary)
                          (funcall completion-in-region-mode--predicate))))
           (corfu--update)
           t)))
      (corfu-quit)))

(defun corfu--goto (index)
  "Go to candidate with INDEX."
  (setq corfu--index (max corfu--preselect (min index (1- corfu--total)))
        ;; Reset auto start in order to disable the `corfu-quit-no-match' timer
        corfu--auto-start nil))

(defun corfu-next (&optional n)
  "Go forward N candidates."
  (interactive "p")
  (let ((index (+ corfu--index (or n 1))))
    (corfu--goto
     (cond
      ((not corfu-cycle) index)
      ((= corfu--total 0) -1)
      ((< corfu--preselect 0) (1- (mod (1+ index) (1+ corfu--total))))
      (t (mod index corfu--total))))))

(defun corfu-previous (&optional n)
  "Go backward N candidates."
  (interactive "p")
  (corfu-next (- (or n 1))))

(defun corfu-scroll-down (&optional n)
  "Go back by N pages."
  (interactive "p")
  (corfu--goto (max 0 (- corfu--index (* (or n 1) corfu-count)))))

(defun corfu-scroll-up (&optional n)
  "Go forward by N pages."
  (interactive "p")
  (corfu-scroll-down (- (or n 1))))

(defun corfu-first ()
  "Go to first candidate, or to the prompt when the first candidate is selected."
  (interactive)
  (corfu--goto (if (> corfu--index 0) 0 -1)))

(defun corfu-last ()
  "Go to last candidate."
  (interactive)
  (corfu--goto (1- corfu--total)))

(defun corfu--restore-on-next-command ()
  "Restore window configuration before next command."
  (let ((config (current-window-configuration))
        (other other-window-scroll-buffer)
        (restore (make-symbol "corfu--restore")))
    (fset restore
          (lambda ()
            (when (memq this-command '(corfu-quit corfu-reset))
              (setq this-command #'ignore))
            (remove-hook 'pre-command-hook restore)
            (setq other-window-scroll-buffer other)
            (set-window-configuration config)))
    (add-hook 'pre-command-hook restore)))

;; Company support, taken from `company.el', see `company-show-doc-buffer'.
(defun corfu-show-documentation ()
  "Show documentation of current candidate."
  (interactive)
  (when (< corfu--index 0)
    (user-error "No candidate selected"))
  (if-let* ((fun (plist-get corfu--extra :company-doc-buffer))
            (res (funcall fun (nth corfu--index corfu--candidates))))
      (let ((buf (or (car-safe res) res)))
        (corfu--restore-on-next-command)
        (setq other-window-scroll-buffer (get-buffer buf))
        (set-window-start (display-buffer buf t) (or (cdr-safe res) (point-min))))
    (user-error "No documentation available")))

;; Company support, taken from `company.el', see `company-show-location'.
(defun corfu-show-location ()
  "Show location of current candidate."
  (interactive)
  (when (< corfu--index 0)
    (user-error "No candidate selected"))
  (if-let* ((fun (plist-get corfu--extra :company-location))
            (loc (funcall fun (nth corfu--index corfu--candidates))))
      (let ((buf (or (and (bufferp (car loc)) (car loc)) (find-file-noselect (car loc) t))))
        (corfu--restore-on-next-command)
        (setq other-window-scroll-buffer buf)
        (with-selected-window (display-buffer buf t)
          (save-restriction
            (widen)
            (if (bufferp (car loc))
                (goto-char (cdr loc))
              (goto-char (point-min))
              (forward-line (1- (cdr loc))))
            (set-window-start nil (point)))))
    (user-error "No candidate location available")))

(defun corfu-complete ()
  "Try to complete current input."
  (interactive)
  (pcase-let ((`(,beg ,end ,table ,pred) completion-in-region--data))
    (if completion-cycling
        ;; Proceed with cycling
        (let ((completion-extra-properties corfu--extra))
          (corfu--completion-in-region beg end table pred))
      (if (>= corfu--index 0)
          ;; Continue completion with selected candidate
          (corfu--insert nil)
        ;; Try to complete the current input string
        (let* ((pt (max 0 (- (point) beg)))
               (str (buffer-substring-no-properties beg end))
               (metadata (completion-metadata (substring str 0 pt) table pred)))
          (pcase (completion-try-completion str table pred pt metadata)
            (`(,newstr . ,newpt)
             (completion--replace beg end newstr)
             (goto-char (+ beg newpt))))))
      ;; No further completion is possible and the current string is a valid
      ;; match, exit with status 'finished.
      (let* ((pt (max 0 (- (point) beg)))
             (str (buffer-substring-no-properties beg end))
             (metadata (completion-metadata (substring str 0 pt) table pred)))
        (when (and (not (consp (completion-try-completion str table pred pt metadata)))
                   (test-completion str table pred))
          (corfu--done str 'finished))))))

(defun corfu--insert (status)
  "Insert current candidate, exit with STATUS if non-nil."
  (pcase-let* ((`(,beg ,end ,table ,pred) completion-in-region--data)
               (str (buffer-substring-no-properties beg end)))
    ;; Replace if candidate is selected or if current input is not valid completion.
    ;; For example str can be a valid path, e.g., ~/dir/.
    (when (or (>= corfu--index 0) (equal str "")
              (not (test-completion str table pred)))
      ;; XXX There is a small bug here, depending on interpretation.
      ;; When completing "~/emacs/master/li|/calc" where "|" is the
      ;; cursor, then the candidate only includes the prefix
      ;; "~/emacs/master/lisp/", but not the suffix "/calc". Default
      ;; completion has the same problem when selecting in the
      ;; *Completions* buffer. See bug#48356.
      (setq str (concat (substring str 0 corfu--base)
                        (substring-no-properties (nth (max 0 corfu--index) corfu--candidates))))
      (completion--replace beg end str)
      (corfu--goto -1)) ;; Reset selection, but continue completion.
    (when status (corfu--done str status)))) ;; Exit with status

(defun corfu--done (str status)
  "Call the `:exit-function' with STR and STATUS and exit completion."
  (let ((exit (plist-get corfu--extra :exit-function)))
    ;; For successfull completions, amalgamate undo operations,
    ;; such that completion can be undone in a single step.
    (undo-amalgamate-change-group corfu--change-group)
    (corfu-quit)
    ;; XXX Is the :exit-function handling sufficient?
    (when exit (funcall exit str status))))

(defun corfu-insert ()
  "Insert current candidate."
  (interactive)
  (if (> corfu--total 0)
      (corfu--insert 'finished)
    (corfu-quit)))

(defun corfu--setup ()
  "Setup Corfu completion state."
  (setq corfu--extra completion-extra-properties)
  (activate-change-group (setq corfu--change-group (prepare-change-group)))
  (setcdr (assq #'completion-in-region-mode minor-mode-overriding-map-alist) corfu-map)
  (add-hook 'pre-command-hook #'corfu--pre-command nil 'local)
  (add-hook 'post-command-hook #'corfu--post-command nil 'local)
  ;; Disable default post-command handling, since we have our own
  ;; checks in `corfu--post-command'.
  (remove-hook 'post-command-hook #'completion-in-region--postch)
  (let ((sym (make-symbol "corfu--teardown"))
        (buf (current-buffer)))
    (fset sym (lambda ()
                ;; Ensure that the teardown runs in the correct buffer, if still alive.
                (unless completion-in-region-mode
                  (remove-hook 'completion-in-region-mode-hook sym)
                  (with-current-buffer (if (buffer-live-p buf) buf (current-buffer))
                    (corfu--teardown)))))
    (add-hook 'completion-in-region-mode-hook sym)))

(defun corfu--teardown ()
  "Teardown Corfu."
  ;; Redisplay such that the input becomes immediately visible before the popup
  ;; hiding, which is slow (Issue #48). See also corresponding vertico#89.
  (redisplay)
  (corfu--popup-hide)
  (remove-hook 'window-configuration-change-hook #'corfu-quit)
  (remove-hook 'pre-command-hook #'corfu--pre-command 'local)
  (remove-hook 'post-command-hook #'corfu--post-command 'local)
  (when corfu--preview-ov (delete-overlay corfu--preview-ov))
  (when corfu--echo-timer (cancel-timer corfu--echo-timer))
  (when corfu--echo-message (corfu--echo-show ""))
  (accept-change-group corfu--change-group)
  (mapc #'kill-local-variable corfu--state-vars))

(defun corfu--completion-message (msg)
  "Print completion MSG, do not hang like `completion--message'."
  (when (and completion-show-inline-help
             (member msg '("No match" "Sole completion")))
    (message msg)))

(defun corfu--all-sorted-completions (&optional beg end)
  "Compute all sorted completions for string between BEG and END."
  (or completion-all-sorted-completions
      (pcase-let ((`(,base ,all . ,_) (corfu--recompute-candidates
                                       (buffer-substring-no-properties beg end)
                                       (max 0 (- (point) beg))
                                       minibuffer-completion-table
                                       minibuffer-completion-predicate)))
        (when all
          (completion--cache-all-sorted-completions
           beg end (nconc all base))))))

(defun corfu--completion-in-region (&rest args)
  "Corfu completion in region function passing ARGS to `completion--in-region'."
  (barf-if-buffer-read-only)
  (if (not (display-graphic-p))
      ;; XXX Warning this can result in an endless loop when `completion-in-region-function'
      ;; is set *globally* to `corfu--completion-in-region'. This should never happen.
      (apply (default-value 'completion-in-region-function) args)
    ;; Restart the completion. This can happen for example if C-M-/
    ;; (`dabbrev-completion') is pressed while the Corfu popup is already open.
    (when (and completion-in-region-mode (not completion-cycling))
      (corfu-quit))
    (prog1
        (cl-letf* ((completion-auto-help nil)
                   ;; Set the predicate to ensure that `completion-in-region-mode' is enabled.
                   (completion-in-region-mode-predicate
                    (or completion-in-region-mode-predicate (lambda () t)))
                   ;; Overwrite to avoid hanging.
                   ((symbol-function #'completion--message)
                    #'corfu--completion-message)
                   ;; Overwrite for performance and consistency.
                   ((symbol-function #'completion-all-sorted-completions)
                    #'corfu--all-sorted-completions))
          (apply #'completion--in-region args))
        (when (and completion-in-region-mode
                   ;; Do not show Corfu when "trivially" cycling, i.e.,
                   ;; when the completion is finished after the candidate.
                   (not (and completion-cycling
                             (pcase-let* ((`(,beg ,end ,table ,pred) completion-in-region--data)
                                          (pt (max 0 (- (point) beg)))
                                          (str (buffer-substring-no-properties beg end))
                                          (before (substring str 0 pt))
                                          (after (substring str pt)))
                               (equal (completion-boundaries before table pred after) '(0 . 0))))))
          (corfu--setup)))))

(defun corfu--auto-complete (buffer)
  "Initiate auto completion after delay in BUFFER."
  (setq corfu--auto-timer nil)
  (when (and (not completion-in-region-mode)
             (eq (current-buffer) buffer))
    (pcase (while-no-input ;; Interruptible capf query
             (run-hook-wrapped 'completion-at-point-functions #'corfu--capf-wrapper))
      ((and `(,fun ,beg ,end ,table . ,plist)
            (guard (integer-or-marker-p beg))
            (guard (<= beg (point) end))
            (guard
             (let ((len (or (plist-get plist :company-prefix-length) (- (point) beg))))
               (or (eq len t) (>= len corfu-auto-prefix)))))
       (let ((completion-extra-properties plist)
             (completion-in-region-mode-predicate
              (lambda () (eq beg (car-safe (funcall fun))))))
         (setq completion-in-region--data `(,(copy-marker beg) ,(copy-marker end t)
                                            ,table ,(plist-get plist :predicate))
               corfu--auto-start (float-time))
         (undo-boundary) ;; Necessary to support `corfu-reset'
         (completion-in-region-mode 1)
         (corfu--setup)
         (corfu--update))))))

(defun corfu--auto-post-command ()
  "Post command hook which initiates auto completion."
  (when corfu--auto-timer
    (cancel-timer corfu--auto-timer)
    (setq corfu--auto-timer nil))
  (when (and (not completion-in-region-mode)
             (corfu--match-symbol-p corfu-auto-commands this-command)
             (display-graphic-p))
    ;; NOTE: Do not use idle timer since this leads to unacceptable slowdowns,
    ;; in particular if flyspell-mode is enabled.
    (setq corfu--auto-timer (run-at-time corfu-auto-delay nil
                                         #'corfu--auto-complete
                                         (current-buffer)))))

;;;###autoload
(define-minor-mode corfu-mode
  "Completion Overlay Region FUnction"
  :global nil :group 'corfu
  (cond
   (corfu-mode
    ;; FIXME: Install advice which fixes `completion--capf-wrapper', such that
    ;; it respects the completion styles for non-exclusive capfs. See FIXME in
    ;; the `completion--capf-wrapper' function in minibuffer.el, where the
    ;; issue has been mentioned. We never uninstall this advice since the
    ;; advice is active *globally*.
    (advice-add #'completion--capf-wrapper :around #'corfu--capf-wrapper-advice)
    (advice-add #'eldoc-display-message-no-interference-p :before-while #'corfu--allow-eldoc)
    (and corfu-auto (add-hook 'post-command-hook #'corfu--auto-post-command nil 'local))
    (setq-local completion-in-region-function #'corfu--completion-in-region))
   (t
    (remove-hook 'post-command-hook #'corfu--auto-post-command 'local)
    (kill-local-variable 'completion-in-region-function))))

(defun corfu--capf-wrapper (fun)
  "Wrapper for `completion-at-point' FUN.
Determines if the capf is applicable at the current position."
  (pcase (funcall fun)
    ((and res `(,beg ,end ,table . ,plist))
     (and (integer-or-marker-p beg) ;; Valid capf result
          (<= beg (point) end) ;; Sanity checking
          ;; For non-exclusive capfs, check for valid completion.
          (or (not (eq 'no (plist-get plist :exclusive)))
              (let* ((str (buffer-substring-no-properties beg end))
                     (pt (- (point) beg))
                     (pred (plist-get plist :predicate))
                     (md (completion-metadata (substring str 0 pt) table pred)))
                (completion-try-completion str table pred pt md)))
          (cons fun res)))))

(defun corfu--capf-wrapper-advice (orig fun which)
  "Around advice for `completion--capf-wrapper'.
The ORIG function takes the FUN and WHICH arguments."
  (if corfu-mode (corfu--capf-wrapper fun) (funcall orig fun which)))

;;;###autoload
(define-globalized-minor-mode corfu-global-mode corfu-mode corfu--on :group 'corfu)

(defun corfu--on ()
  "Turn `corfu-mode' on."
  (unless (or noninteractive
              (eq (aref (buffer-name) 0) ?\s)
              (memq major-mode corfu-excluded-modes))
    (corfu-mode 1)))

(defun corfu--allow-eldoc ()
  "Return non-nil if Corfu is currently not active."
  (not (and corfu-mode completion-in-region-mode)))

;; Emacs 28: Do not show Corfu commands with M-X
(dolist (sym '(corfu-next corfu-previous corfu-first corfu-last corfu-quit corfu-reset
               corfu-complete corfu-insert corfu-scroll-up corfu-scroll-down
               corfu-show-location corfu-show-documentation))
  (put sym 'completion-predicate #'ignore))

(provide 'corfu)
;;; corfu.el ends here
