;;; sgf.el --- Smart Game Format (focused on GO)

;; http://www.red-bean.com/sgf/sgf4.html
;; http://www.red-bean.com/sgf/properties.html

;;; BNF
;; Collection = GameTree { GameTree }
;; GameTree   = "(" Sequence { GameTree } ")"
;; Sequence   = Node { Node }
;; Node       = ";" { Property }
;; Property   = PropIdent PropValue { PropValue }
;; PropIdent  = UcLetter { UcLetter }
;; PropValue  = "[" CValueType "]"
;; CValueType = (ValueType | Compose)
;; ValueType  = (None | Number | Real | Double | Color | SimpleText |
;;       	Text | Point  | Move | Stone)

;;; There are two types of property lists: 'list of' and 'elist of'. 
;; 'list of':    PropValue { PropValue }
;; 'elist of':   ((PropValue { PropValue }) | None)
;;               In other words elist is list or "[]".

;;; Property Value Types
;; UcLetter   = "A".."Z"
;; Digit      = "0".."9"
;; None       = ""
;; Number     = [("+"|"-")] Digit { Digit }
;; Real       = Number ["." Digit { Digit }]
;; Double     = ("1" | "2")
;; Color      = ("B" | "W")
;; SimpleText = { any character (handling see below) }
;; Text       = { any character (handling see below) }
;; Point      = game-specific
;; Move       = game-specific
;; Stone      = game-specific
;; Compose    = ValueType ":" ValueType

;; an example is at the bottom of the page

;;; Comments:

;; - an sgf tree is just a series of nested lists.
;; - a pointer into the tree marks the current location
;; - navigation using normal Sexp movement
;; - games build such trees as they go
;; - a board is just one interface into such a tree

;;; Code:
(defun char-to-offset (char)
  (if (< char ?a)
      (+ 26 (- char ?A))
    (- char ?a)))

(defmacro parse-many (regexp string &rest body)
  (declare (indent 2))
  `(let (res (start 0))
     (flet ((collect (it) (push it res)))
       (while (string-match ,regexp ,string start)
         (setq start (match-end 0))
         (save-match-data ,@body))
       (nreverse res))))
(def-edebug-spec parse-many (regexp string body))

(defvar parse-prop-val-re
  "[[:space:]\n\r]*\\[\\([^\000]*?[^\\]\\)\\]")

(defvar parse-prop-re
  (format "[[:space:]\n\r]*\\([[:alpha:]]+\\(%s\\)+\\)" parse-prop-val-re))

(defvar parse-node-re
  (format "[[:space:]\n\r]*;\\(\\(%s\\)+\\)" parse-prop-re))

(defvar parse-tree-part-re
  (format "[[:space:]\n\r]*(\\(%s\\)[[:space:]\n\r]*\\([()]\\)" parse-node-re))

(defun parse-prop-ident (str)
  (let ((end (if (and (<= ?A (aref str 1))
                      (< (aref str 1) ?Z))
                 2 1)))
    (values (substring str 0 end)
            (substring str end))))

(defun parse-prop-vals (str)
  (parse-many parse-prop-val-re str
    (collect (match-string 1 str))))

(defun parse-prop (str)
  (multiple-value-bind (id rest) (parse-prop-ident str)
    (cons id (parse-prop-vals rest))))

(defun parse-props (str)
  (parse-many parse-prop-re str
    (multiple-value-bind (id rest) (parse-prop-ident (match-string 1 str))
      (collect (cons id (parse-prop-vals rest))))))

(defun parse-nodes (str)
  (parse-many parse-node-re str
    (collect (parse-props (match-string 1 str)))))

(defun parse-trees (str)
  (let (cont-p)
    (parse-many parse-tree-part-re str
      (setq start (match-beginning 2))
      (let ((tree-part (parse-nodes (match-string 1 str))))
        (setq res (if cont-p
                      (list tree-part res)
                    (cons tree-part res)))
        (setq cont-p (string= (match-string 2 str) "("))))))

(defun parse-from-buffer (buffer)
  (parse-trees (with-current-buffer buffer (buffer-string))))

(defun parse-from-file (file)
  (with-temp-buffer
    (insert-file-contents-literally file)
    (parse-from-buffer (current-buffer))))


;;; Tests
(require 'ert)

(ert-deftest sgf-parse-prop-tests ()
  (flet ((should= (a b) (should (tree-equal a b :test #'string=))))
    (should= (parse-props "B[pq]") '(("B" "pq")))
    (should= (parse-props "GM[1]") '(("GM" "1")))
    (should= (parse-props "GM[1]\nB[pq]\tB[pq]")
             '(("GM" "1") ("B" "pq") ("B" "pq")))
    (should (= (length (cdar (parse-props "TB[as][bs][cq][cr][ds][ep]")))
               6))))

(ert-deftest sgf-parse-multiple-small-nodes-test ()
  (let* ((str ";B[pq];W[dd];B[pc];W[eq];B[cp];W[cm];B[do];W[hq];B[qn];W[cj]")
         (nodes (parse-nodes str)))
    (should (= (length nodes) 10))
    (should (tree-equal (car nodes) '(("B" "pq")) :test #'string=))))

(ert-deftest sgf-parse-one-large-node-test ()
  (let* ((str ";GM[1]FF[4]
               SZ[19]
               GN[GNU Go 3.7.11 load and print]
               DT[2008-12-14]
               KM[0.0]HA[0]RU[Japanese]AP[GNU Go:3.7.11]AW[ja][oa]
               [pa][db][eb]")
         (node (car (parse-nodes str))))
    (should (= (length node) 10))
    (should (= (length (cdar (last node))) 5))))

(ert-deftest sgf-parse-simple-tree ()
  (let* ((str "(;GM[1]FF[4]
               SZ[19]
               GN[GNU Go 3.7.11 load and print]
               DT[2008-12-14]
               KM[0.0]HA[0]RU[Japanese]AP[GNU Go:3.7.11]AW[ja][oa]
               [pa][db][eb])")
         (tree (parse-trees str)))
    (should (= 1  (length tree)))
    (should (= 1  (length (car tree))))
    (should (= 10 (length (caar tree))))))

(ert-deftest sgf-parse-nested-tree ()
  (let* ((str "(;GM[1]FF[4]
               SZ[19]
               GN[GNU Go 3.7.11 load and print]
               DT[2008-12-14]
               KM[0.0]HA[0]RU[Japanese]AP[GNU Go:3.7.11]
               (;AW[ja][oa][pa][db][eb] ;AB[fa][ha][ia][qa][cb]))")
         (tree (parse-trees str)))
    (should (= 2  (length tree)))
    (should (= 9 (length (car (first tree)))))
    (should (= 2 (length (second tree))))))

(ert-deftest sgf-parse-file-test ()
  (let ((game (car (parse-from-file "games/jp-ming-5.sgf"))))
    (should (= 247 (length game)))))
