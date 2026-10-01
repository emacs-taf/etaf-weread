;;; etaf-weread-theme.el --- Palette and ETAF UI theme for etaf-weread -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The reader renders its own surface instead of borrowing the user's Emacs
;; theme, so it looks the same in every session.  `etaf-weread-color' is the
;; palette lookup used by the Views; `etaf-weread-theme-defaults' projects the
;; same palette onto the ETAF UI token contract consumed by etaf-ui Components
;; (buttons, text inputs, progress bars).

;;; Code:

(require 'etaf)

(define-error 'etaf-weread-error "WeChat Reading reader error")

(defgroup etaf-weread nil
  "WeChat Reading client built with ETAF and Ebox."
  :group 'applications)

(defconst etaf-weread--palettes
  '((dark :bg "#0F1216" :panel "#151A21" :panel2 "#1B212B" :panel3 "#232B37"
          :line "#242C38" :ink "#E8ECF2" :muted "#9AA5B4" :dim "#66707F"
          :accent "#5B8DEF" :accent-soft "#1A2436" :gold "#E4B15E" :ok "#4FBF8B"
          :warn "#E4B15E" :danger "#FF7A85" :danger-bg "#3A1E24" :info "#6FB4E8"
          :selected "#1B2330" :meter "#5B8DEF" :cover "#232B37" :quote "#8EA8D8")
    (light :bg "#FFFFFF" :panel "#F7F8FA" :panel2 "#EDF0F4" :panel3 "#E1E6EC"
           :line "#E1E6EC" :ink "#1C2330" :muted "#5A6371" :dim "#8A93A0"
           :accent "#2F6FED" :accent-soft "#E8EFFD" :gold "#B07A16" :ok "#2E7D5B"
           :warn "#B07A16" :danger "#C0392B" :danger-bg "#FBE4E2" :info "#2C6FA8"
           :selected "#EDF0F4" :meter "#2F6FED" :cover "#E1E6EC" :quote "#4A6FC0"))
  "Palette of every supported appearance, keyed by mode.")

(defcustom etaf-weread-theme-mode 'dark
  "Appearance used by a new reader session.
`dark' (default) renders the reader's own dark surface; `light' uses the light
palette.  This is independent of the active Emacs theme."
  :type '(choice (const :tag "Dark" dark) (const :tag "Light" light))
  :group 'etaf-weread)

(defun etaf-weread-color (key &optional mode)
  "Return the palette color named KEY.
MODE defaults to `etaf-weread-theme-mode'.  An unknown KEY signals
`etaf-weread-error' instead of returning a fallback, because a typo would
otherwise paint an invisible surface."
  (let* ((mode (if (eq (or mode etaf-weread-theme-mode) 'light) 'light 'dark))
         (palette (cdr (assq mode etaf-weread--palettes)))
         (color (plist-get palette key)))
    (unless (and (keywordp key) color)
      (signal 'etaf-weread-error (list (format "Unknown color: %S" key))))
    color))

(defun etaf-weread-theme-defaults (&optional mode)
  "Return the ETAF UI token plist for MODE.
MODE defaults to `etaf-weread-theme-mode'.  The result is passed to
`etaf-theme-provide' by the application so shared etaf-ui Components use the
same colors as the reader's own Views."
  (let* ((dark (not (eq (or mode etaf-weread-theme-mode) 'light)))
         (bg (etaf-weread-color :bg mode))
         (panel (etaf-weread-color :panel mode))
         (panel3 (etaf-weread-color :panel3 mode))
         (ink (etaf-weread-color :ink mode))
         (line (etaf-weread-color :line mode))
         (muted (etaf-weread-color :muted mode))
         (accent (etaf-weread-color :accent mode))
         (accent-soft (etaf-weread-color :accent-soft mode))
         (ok (etaf-weread-color :ok mode))
         (ok-bg (if dark "#17301F" "#E3F3E8"))
         (ok-border (if dark "#2E5C3F" "#A9D8BB"))
         (danger (etaf-weread-color :danger mode))
         (danger-bg (if dark "#3A1E24" "#FBE4E2"))
         (danger-border (if dark "#7A2A2C" "#E8B4AE"))
         (warn (etaf-weread-color :warn mode))
         (warn-bg (if dark "#33280F" "#FBF0DA"))
         (warn-border (if dark "#6B5423" "#E0C48A"))
         (info (etaf-weread-color :info mode))
         (info-bg (if dark "#14232F" "#E4F0FA"))
         (info-border (if dark "#2C4E66" "#A8CBE6")))
    (list
     :ink ink :paper bg :panel panel :line line :muted muted
     :accent accent :accent-soft accent-soft
     :ui-fg ink :ui-bg bg :ui-border line :ui-muted-fg muted
     :ui-disabled-fg muted :ui-disabled-bg panel :ui-disabled-border line
     :ui-accent accent :ui-accent-fg "#FFFFFF" :ui-accent-soft-bg accent-soft
     :ui-button-primary-fg "#FFFFFF" :ui-button-primary-bg accent
     :ui-button-secondary-fg accent :ui-button-secondary-bg accent-soft
     :ui-button-ghost-fg muted
     :ui-success-fg ok :ui-success-bg ok-bg :ui-success-border ok-border
     :ui-danger-fg danger :ui-danger-bg danger-bg :ui-danger-border danger-border
     :ui-warning-fg warn :ui-warning-bg warn-bg :ui-warning-border warn-border
     :ui-info-fg info :ui-info-bg info-bg :ui-info-border info-border
     :ui-panel-fg ink :ui-panel-bg panel :ui-panel-border line
     :ui-divider-bg line
     :ui-progress-track panel3 :ui-progress-value accent
     :ui-table-border line :ui-table-selected-fg accent
     :ui-table-selected-bg accent-soft
     :ui-shell-bg panel :ui-shell-fg ink :ui-shell-muted-fg muted
     :ui-shell-item-fg muted :ui-shell-item-minimized-fg muted
     :ui-window-bg bg :ui-window-fg ink :ui-window-border line
     :ui-window-title-bg panel :ui-window-title-fg muted
     :ui-window-title-active-fg ink
     :ui-picker-item-bg panel :ui-picker-item-fg ink
     :ui-picker-item-muted-fg muted
     :ui-pagination-muted-fg muted
     :ui-data-grid-error-fg danger
     :ui-checkbox-enabled-fg ink :ui-checkbox-disabled-fg muted)))

(provide 'etaf-weread-theme)
;;; etaf-weread-theme.el ends here
