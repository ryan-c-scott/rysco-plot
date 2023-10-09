;;; -*- lexical-binding: t; -*-
(require 'cl)

(defvar rysco-plot-error-buffer-name "*gnuplot errors*"
  "Buffer name to use when reporting error output from gnuplot")

(cl-defun rysco-plot--guess-filename (&optional ext)
  (when (boundp 'out)
    out)
  (when (equal major-mode 'org-mode)
    (concat
     (replace-regexp-in-string
      "[/\\:]" "-"
      (s-join "-" (org-get-outline-path t)))
     (concat "." (or ext "svg")))))

(cl-defun rysco-plot--render-functions (form)
  (pcase form
    (`(,func . ,params)
     (pcase func
       ((or '* '/ '+ '-)
        (cl-loop
         with last
         with op = (format "%s" func)
         for chunk in params
         if last concat op
         concat (rysco-plot--render-functions chunk)
         do (setq last chunk)))

       (_
        (format "%s%s" func params))))

    ((pred stringp)
     (format "\"%s\"" form))

    (_ (format "%s" form))))

(cl-defun rysco-plot--key-p (el)
  (= (aref
      (format "%s" el)
      0)
     ?\:))

(cl-defun rysco-plot--key-to-string (key)
  (let ((s (format "%s" key)))
    (if (= (aref s 0) ?\:)
        (substring s 1)
      s)))

(cl-defun rysco-plot--render-options (options)
  (cl-loop
   for el in options do
   (rysco-plot--render-element el)
   (insert " ")))

(cl-defun rysco-plot--render-range (range)
  (insert
   "["
   (s-join
    " : "
    (mapcar
     (lambda (it)
       (format
        "%s"
        (rysco-plot--render-functions it)))
     (append range nil)))
   "]"))

(cl-defun rysco-plot--render-element (el)
   (pcase el
     ((pred symbolp)
      (insert (rysco-plot--key-to-string el)))

     ((pred listp)
      (insert
       (s-join
        ", "
        (mapcar
         (lambda (it)
           (format
            "%s"
            (rysco-plot--render-functions it)))
         el))))

     ((pred stringp)
      (insert (format "\"%s\"" el)))

     ((pred vectorp)
      (rysco-plot--render-range el))

     (_
      (insert (format "%s" el)))))

(cl-defun rysco-plot--render-generic-entry (entry)
  (cl-loop
   for el in entry
   do
   (rysco-plot--render-element el)
   do (insert " ")))

(cl-defun rysco-plot-gnuplot-command (path)
  ;; TODO: Variable for gnuplot binary path
  (format "gnuplot \"%s\"" path)
  )

(cl-defun rysco-plot--render-data (name data)
  (insert (format "$%s << EOD\n" name))
  (cl-loop
   for entry in data do
   (cl-loop
    with sep
    for el in entry do
    (insert
     (format
      "%s%s"
      (or sep "")
      (pcase el
        ((pred stringp) (concat "\"" el "\""))
        (_ el))))
    as sep = ", ")
   do (insert "\n"))
  (insert "EOD\n")
  (insert "set datafile separator \",\"\n"))

(cl-defun rysco-plot--render-dependency-data (name data)
  "Renders data as a dependency sorted table.

Data Format:
  '(((a . \"System A\") (b . 1))
    ((b . \"System B\") (c . 5))
    ((c . \"System C\")))"

  (let* ((names (--map (caar it) data))
         (labels (--map (car it) data))
         (systems (cl-loop
                   for ((sys . _) . deps) in data collect
                   `(,sys . ,(--map (if (listp it) it `(,it . 1)) deps))))
         (scores (--map (cons (car it) (length (cdr it))) systems))
         (names (--sort
                 (> (or (cdr (assoc it scores)) 0) (or (cdr (assoc other scores)) 0))
                 names)))

    (rysco-plot--render-data
     name
     (cons
      (cons "" (--map (cdr (assoc it labels)) names))
      (cl-loop
       for r in names
       collect
       (cons
        (cdr (assoc r labels))
        (cl-loop
         for c in names
         as deps = (cdr (assoc c systems))
         as weight = (cdr (assoc r deps))
         collect
         (cond
          ((equal r c) 0)
          (weight weight)
          (t 0)))))))))

(cl-defun rysco-plot--render-tics (name options data)
  (insert (format "set %stics " name))
  (rysco-plot--render-options options)
  (insert
   " ("
   (s-join
    ", "
    (cl-loop
     for entry in data collect
     (pcase entry
       (`(,label ,val . ,rest)
        (format "\"%s\" %s %s"
                label
                val
                (or (car rest) "")))
       (_
        (format "%s" entry)))
     ))
   ")"))

(cl-defun rysco-plot--render-plot (data)
  (insert "plot ")
  (cl-loop
   with plot-count = (length data)

   for i from 1
   for plot in data

   as plot-options = nil
   as skip-sep = (= i plot-count)
   do

   (pcase plot
     ((pred vectorp)
      (setq skip-sep t)
      (rysco-plot--render-range plot))

     ((and `(,type . ,plot-data) (guard (rysco-plot--key-p type)))
      (cl-loop
       for (k v) on plot-data by 'cddr do
       (pcase k
         (:data
          (pcase v
            (`(,name . ,options)
             (insert (format "$%s " name))
             (rysco-plot--render-options options))
            (_ (insert (format "$%s " v)))))

         (:options
          (when (listp v)
            (setq plot-options v)))

         (:using
          (insert
           "using "
           (s-join
            ":"
            (mapcar
             (lambda (it)
               (format
                "%s"
                (rysco-plot--render-functions it)))
             (append v nil)))
           " "))

         (:fun
          (insert
           (format
            "%s"
            (rysco-plot--render-functions v))))

         (_
          (insert
           (rysco-plot--key-to-string k)
           " ")
          (rysco-plot--render-element v))))
      (insert (format " with %s"
                      (pcase type
                        (:image-pixel "image pixel")
                        (_ (rysco-plot--key-to-string type)))))
      (when plot-options
        (insert " ")
        (rysco-plot--render-options plot-options))))

   do (insert (concat (unless skip-sep ",") " "))))

(cl-defun rysco-plot--mark-errors (errors)
  (cl-loop
   with info = (-partition-all 6 (s-split "\n" errors))
   for (_ line pointer err _) in info
   do
   (pcase-let* (((rx (* any) "line " (let line (+ digit)) ": " (let msg (+ any))) err)
                (beg))
     (save-excursion
       (goto-char (point-min))
       (forward-line (1- (cl-parse-integer line)))
       (setq beg (point))
       (forward-line 1)
       (--when-let (make-overlay beg (point))
         (overlay-put it 'after-string (propertize (format "%s\n\t%s\n" pointer msg) 'face 'font-lock-warning-face)))))))

(cl-defun rysco-plot-report-errors (code errors)
  (with-current-buffer (get-buffer-create rysco-plot-error-buffer-name)
    (remove-overlays)
    (erase-buffer)
    (insert code)
    (rysco-plot--mark-errors errors)))

(cl-defun rysco-plot--render (form &key filename as-code debug-data)
  "Generate gnuplot file from `FORM' and render image from it."
  (let ((path (f-full filename)))
    (with-temp-buffer
      (insert (format "set output \"%s\"\n" path))

      (cl-loop
       for entry in form do
       (pcase entry
         (`(:env ,name ,value)
          (insert
           (format "%s = %s" name value)))

         (`(:data ,name . ,data)
          (if (and as-code (not debug-data))
              (insert "<<DATA OMITTED>>")
            (rysco-plot--render-data name data)))

         (`(:dependency-data ,name . ,data)
          (if (and as-code (not debug-data))
              (insert "<<DATA OMITTED>>")
            (rysco-plot--render-dependency-data name data)))

         ((and `(:tics ,name . ,_) (map :options :data))
          (rysco-plot--render-tics name options data))

         (`(:plot . ,data)
          (rysco-plot--render-plot data))

         (_
          (rysco-plot--render-generic-entry entry)))

       do (insert "\n"))
      (cond
       (as-code
        (buffer-string))
       (t
        (let* ((temp-path (make-temp-file "rysco" nil ".plot")))
          (write-file temp-path)

          (let ((output (shell-command-to-string
                         (rysco-plot-gnuplot-command temp-path))))
            (unless (string-empty-p output)
              (message "Error in plotting. See %s" rysco-plot-error-buffer-name)
              (rysco-plot-report-errors (buffer-string) output)))

          (delete-file temp-path))
        filename)))))

(cl-defun rysco-plot--process-date-log (&key title data col map start end miny maxy)
  `((:set :title ,title)
    (:set :xdata time)
    (:set :timefmt "%Y-%m-%d")
    (:set :format x "%m/%y")
    (:set :xrange [,(or start '*) ,(or end '*)])
    (:set :yrange [,(or miny '*) ,(or maxy '*)])

    (:plot
     ,@(cl-loop
        for period-title in map
        for i from (or col 3)
        collect
        `(:lines :data ,data :using [1 ,i] :title ,period-title)))))

(cl-defun rysco-plot--process-dependency-matrix (&key title data)
  `((:set :title ,title)
    (:unset key)

    (:set yrange [* *] :reverse)

    (:set size ratio 1)

    (:set xtics rotate by 90 right)
    (:set ytics right)

    (:set link x)
    (:set link y)

    (:set x2tics 1 format "" scale (0 0.001))
    (:set y2tics 1 format "" scale (0 0.001))

    (:set mx2tics 2)
    (:set my2tics 2)

    (:set xtics 5 out nomirror)
    (:set ytics 5 out nomirror)

    (:set grid front mx2tics my2tics lw 0.5 lt -1 lc rgb "black")

    (:plot
     (:image-pixel :data (,data :matrix :columnheaders :rowheaders))
     (:lines :fun x))))

(cl-defun rysco-plot--process (form &key type dimensions fontscale background)
  "Expand all special commands and inject default forms for the conversion to gnuplot."
  (append `((:set :terminal
                  ,(pcase type
                     ('png "pngcairo")
                     ('nil "svg")
                     (_ type))
                  enhanced
                  font "helvetica,12" fontscale ,(or fontscale 1.0)
                  size ,(or dimensions '(800 700))
                  background rgb ,(or background "#ffffff00")))
          (cl-loop
           for el in form append
           (pcase el
             (`(:plot-date-log . ,rest)
              (apply 'rysco-plot--process-date-log rest))
             (`(:plot-dependency-matrix . ,rest)
              (apply 'rysco-plot--process-dependency-matrix rest))
             (_ `(,el))))))

;;;###autoload
(cl-defun rysco-plot (form &key filename as-code debug-data type dimensions fontscale background)
  (rysco-plot--render
   (rysco-plot--process form :type type :dimensions dimensions :fontscale fontscale :background background)
   :filename (or filename (rysco-plot--guess-filename (and type (format "%s" type))))
   :as-code as-code
   :debug-data debug-data))

;;
(provide 'rysco-plot)
