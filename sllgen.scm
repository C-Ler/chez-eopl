;;; sllgen -- Scheme LL(1) parser generator

;; (let ((time-stamp "Time-stamp: <2000-09-25 11:48:47 wand>"))
;;   (display (string-append
;;              "sllgen.scm "
;;              (substring time-stamp 13 29)
;;              (string #\newline))))

;;; ****************************************************************

;;; Table of contents:

;;; top.s                     top-level entries
;;; parser-gen.scm            organization of parser generator
;;; syntax.s                  concrete syntax for grammars, etc.
;;; eliminate-arbno.s         replaces (ARBNO lhs) items with new productions
;;; first-and-follow.s        calculate first and follow sets
;;; gen-table.s               take list of productions, first and
;;;                           follow tables, and generate parsing table
;;; check-table.s             take a parse table and check for conflicts
;;; scan.s                    scanner using streams
;;; parse.s                   run the generated parser
;;; error handling
;;; tests

;;; ****************************************************************

;;; Mon Sep 25 11:48:13 2000 added scanner outcomes symbol, number,
;;; string to replace make-symbol, make-number, and make-string.

;;; Wed Apr 12 14:15:24 2000 version intended to be R5RS-compliant,
;;; based on suggestions by Will Clinger.

;;; ****************************************************************

;;; be sure to load compatibility files!!

;;; ****************************************************************

;;; top.s

;;; user-level entry points

(define sllgen:make-string-parser
  (lambda (scanner-spec grammar)
    (let ((parser (sllgen:make-parser grammar))
          (scanner (sllgen:make-scanner
                     (append
                       (sllgen:grammar->string-literal-scanner-spec
                         grammar)
                       scanner-spec))))
      (lambda (string)
        (let* ((char-stream (sllgen:string->stream string))
               (token-stream (scanner char-stream))
               (last-line (sllgen:char-stream->location char-stream)))
          (parser
            (sllgen:stream-add-sentinel-via-thunk
              token-stream
              (lambda ()
                (sllgen:make-token 'end-marker #f
                  (sllgen:char-stream->location char-stream))))
            (lambda (tree token token-stream)
              (if (null? token)
                (sllgen:stream-get! token-stream
                  (lambda (tok1 str1)
                    (set! token tok1)
                    (set! token-stream str1))
                  (lambda ()
                    (sllgen:error 'sllgen:string-parser
                      "~%Internal error: shouldn't run off end of stream with sentinels"))))
              (if (eq? (sllgen:token->class token) 'end-marker)
                tree
                (sllgen:error 'parsing
                  "at line ~s~%Symbols left over: ~s ~s etc..."
                  (sllgen:token->location token)
                  (sllgen:token->class token)
                  (sllgen:token->data token))))))))))

(define sllgen:make-stream-scanner
  (lambda (scanner-spec grammar)
    (sllgen:make-scanner
      (append
        (sllgen:grammar->string-literal-scanner-spec
          grammar)
        scanner-spec))))

(define sllgen:make-string-scanner
  (lambda (scanner-spec grammar)
    (let ((scanner (sllgen:make-stream-scanner scanner-spec grammar)))
      (lambda (string)
        (sllgen:stream->list
          (scanner (sllgen:string->stream string)))))))

(define sllgen:make-define-datatypes
  (lambda (scanner-spec grammar)
    (let ((datatype-definitions
            (sllgen:build-define-datatype-definitions scanner-spec grammar)))
                                        ;(sllgen:pretty-print datatype-definitions)
      (for-each
        (lambda (dd) (eval dd (interaction-environment)))
        datatype-definitions))))

(define sllgen:show-define-datatypes
  (lambda (scanner-spec grammar)
    (let ((datatype-definitions
            (sllgen:build-define-datatype-definitions scanner-spec grammar)))
      (for-each
        sllgen:pretty-print
        datatype-definitions))))

(define sllgen:list-define-datatypes
  (lambda (scanner-spec grammar)
    (sllgen:build-define-datatype-definitions scanner-spec grammar)))

(define sllgen:make-stream-parser
  (lambda (scanner-spec grammar)
    (let ((parser (sllgen:make-parser grammar))
          (scanner (sllgen:make-scanner
                     (append
                       (sllgen:grammar->string-literal-scanner-spec
                         grammar)
                       scanner-spec))))
      (lambda (char-stream)
        (let ((stream
                (sllgen:stream-add-sentinel-via-thunk
                  (scanner char-stream)
                  (lambda ()
                    (sllgen:make-token 'end-marker #f
                      (sllgen:char-stream->location char-stream))))))
          (let loop ((stream stream))
            (lambda (fn eos)
              ((parser stream
                 (lambda (tree token token-stream)
                   (sllgen:make-stream 'tag1
                     tree
                     (lambda (fn eos)   ; prevent evaluation for now
                       ((loop
                          ;; push the lookahead token back on the
                          ;; stream iff it's there.
                          (if (null? token)
                            token-stream
                            (sllgen:make-stream 'tag2 token token-stream)))
                        fn eos)))))
               fn eos))))))))

(define sllgen:make-rep-loop
  (lambda (prompt eval-fn stream-parser)
    (lambda ()
      (display prompt)
      (let loop
        ((ast-stream (stream-parser (sllgen:stdin-char-stream))))
        ;; these seem not to make a difference
        ;; (flush-output-port)               ; chez
        ;; (flush-output)                    ; dr scheme
        (sllgen:stream-get! ast-stream
          (lambda (tree stream)
            (write (eval-fn tree))
            (newline)
            (display prompt)
            (loop stream))
          (lambda () #t))))))



;;; ****************************************************************
;;; ****************************************************************

;;; parser-gen.scm

;;; Steps in parser generation:

;;; 1.  Eliminate arbno's by making new nonterms with goto's and
;;; emit-list's.

;;; 2.  Factor productions with common prefixes (not in this version).

;;; 3.  Compute first and follow sets

;;; 4.  Compute prediction table & generate actions

;;; ****************************************************************

;; parser = token-stream * ((tree * token * token-stream) -> ans) -> ans
;; token-stream should be terminated by end-marker token.

(define sllgen:make-parser
  (lambda (grammar)
    (sllgen:grammar-check-syntax grammar)
    (sllgen:initialize-non-terminal-table! grammar)
    (sllgen:arbno-initialize-table!)
    (let ((parse-table (sllgen:build-parse-table grammar))
          (start-symbol (sllgen:grammar->start-symbol grammar)))
      (lambda (token-stream k)       ; k : (tree * token * token-stream) -> ans
         (sllgen:find-production start-symbol parse-table
              '() '() token-stream k)))))


(define the-table 'ignored)

(define sllgen:build-parse-table
  (lambda (grammar)
    (let* ((g (sllgen:eliminate-arbnos-from-productions grammar))
           (first-table (sllgen:first-table g))
           (follow-table (sllgen:follow-table
                           (sllgen:grammar->start-symbol grammar)
                           g
                           first-table))
           (table
             (sllgen:productions->parsing-table g first-table
               follow-table)))
;       (sllgen:pretty-print first-table)
;       (sllgen:pretty-print follow-table)
;        (sllgen:pretty-print table)
      (set! the-table table)
      (sllgen:check-table table)
      table)))


;;; ****************************************************************

;;; syntax.s :  concrete syntax for grammars, etc.

;;; ****************************************************************

;;; Concrete Syntax for grammars

;;; <Grammar> ::= (<production> ...)  ;; nonterm of first prod is
;;;                                      start symbol.
;;; <production> ::= (lhs rhs action)
;;;
;;; lhs ::= symbol                    ;; a symbol that appears in a
;;;                                      lhs is a non-term, all others
;;;                                      are terminals
;;; rhs ::= (rhs-item ...)
;;;
;;; rhs-item ::= string | symbol | (ARBNO . rhs) | (SEPARATED-LIST nt token)
;;;
;;; action ::= symbol | EMIT-LIST | (GOTO lhs)
;;; EMIT-LIST and (GOTO lhs) are not allowed in user input.

;;; ****************************************************************

;;; Auxiliaries for dealing with syntax of grammars

;;; need to define sllgen:grammar-check-syntax

(define sllgen:check
  (lambda (test format . args)
    (lambda (obj)
      (or (test obj)
        (apply sllgen:error
          `(parser-generation ,format . ,args))))))

(define sllgen:grammar-check-syntax
  (lambda (grammar)
    ((sllgen:list-of sllgen:production-check-syntax)
     grammar)))

(define sllgen:production-check-syntax
  (lambda (production)
    ((sllgen:tuple-of
      (sllgen:check symbol? "lhs of production not a symbol: ~s"
        production)
      (sllgen:rhs-check-syntax production)
      (sllgen:check symbol?
        "action of production not a symbol: ~s"
        production))
     production)))

(define sllgen:rhs-check-syntax
  (lambda (production)
    (sllgen:list-of
      (sllgen:rhs-item-check-syntax production))))

(define sllgen:rhs-item-check-syntax
  (lambda (production)
    (lambda (rhs-item)
      ((sllgen:check
         (sllgen:either
           string?
           symbol?
           (sllgen:pair-of
             (lambda (v) (eqv? v 'arbno))
             (sllgen:rhs-check-syntax production))
           sllgen:really-separated-list?
           )
         "illegal rhs item ~s in production ~s"
         rhs-item production)
       rhs-item))))

(define sllgen:really-separated-list?
  (lambda (rhs-item)
    (and (pair? rhs-item)
         (eq? (car rhs-item) 'separated-list)
         (> (length rhs-item) 2)
         (sllgen:rhs-check-syntax (cdr rhs-item))
         (let
           ; ((last-item (car (last-pair rhs-item))))
           ((last-item (sllgen:last rhs-item)))
           (or (symbol? last-item) (string? last-item))))))

(define sllgen:pair-of
  (lambda (pred1 pred2)
    (lambda (obj)
      (and (pair? obj)
        (pred1 (car obj))
        (pred2 (cdr obj))))))

(define sllgen:list-of
  (lambda (pred)
    (lambda (obj)
      (or (null? obj)
          (and (pair? obj)
               (pred (car obj))
               ((sllgen:list-of pred) (cdr obj)))))))

(define sllgen:tuple-of
  (lambda preds
    (lambda (obj)
      (let loop ((preds preds) (obj obj))
        (if (null? preds)
          (null? obj)
          (and (pair? obj)
            ((car preds) (car obj))
            (loop (cdr preds) (cdr obj))))))))

(define sllgen:either
  (lambda preds
    (lambda (obj)
      (let loop ((preds preds))
        (cond
          ((null? preds) #f)
          (((car preds) obj) #t)
          (else (loop (cdr preds))))))))


(define sllgen:grammar->productions
  (lambda (gram) gram))                 ; nothing else now, but this
                                        ; might change

(define sllgen:grammar->start-symbol
  (lambda (gram)
    (sllgen:production->lhs
      (car
        (sllgen:grammar->productions gram)))))

(define sllgen:make-production
  (lambda (lhs rhs action)
    (list lhs rhs action)))

(define sllgen:production->lhs car)
(define sllgen:production->rhs cadr)
(define sllgen:production->action caddr)

(define sllgen:productions->non-terminals
  (lambda (productions)
    (map sllgen:production->lhs productions)))

(define sllgen:arbno?
  (lambda (rhs-item)
    (and (pair? rhs-item)
         (eq? (car rhs-item) 'arbno))))

(define sllgen:arbno->rhs cdr)

(define sllgen:separated-list?
  (lambda (rhs-item)
    (and (pair? rhs-item)
         (eq? (car rhs-item) 'separated-list)
         (> (length rhs-item) 2))))

;;; (separated-list rhs-item ... separator)

(define sllgen:separated-list->nonterm cadr)

(define sllgen:separated-list->separator
  (lambda (item)
    (let loop ((items (cdr item)))
      (cond
        ((null? (cdr items)) (car items))
        (else (loop (cdr items)))))))

(define sllgen:separated-list->rhs
  (lambda (item)
    (let loop ((items (cdr item)))
      (cond
        ((null? (cdr items)) '())
        (else (cons (car items) (loop (cdr items))))))))

(define sllgen:goto-action
  (lambda (lhs) (list 'goto lhs)))

(define sllgen:emit-list-action
  (lambda () '(emit-list)))

(define sllgen:grammar->string-literals ; apply this after arbnos have
                                        ; been eliminated.
  (lambda (grammar)
    (apply append
           (map
             (lambda (production)
               (sllgen:rhs->string-literals
                 (sllgen:production->rhs production)))
             grammar))))

(define sllgen:rhs->string-literals
  (lambda (rhs)
    (let loop ((rhs rhs))
      (cond
        ((null? rhs) '())
        ((string? (car rhs)) (cons (car rhs) (loop (cdr rhs))))
        ((pair? (car rhs)) (append (loop (cdar rhs)) (loop (cdr rhs))))
        (else (loop (cdr rhs)))))))

(define sllgen:grammar->string-literal-scanner-spec
  (lambda (grammar)
    (let ((class (sllgen:gensym 'literal-string)))
      (map
        (lambda (string) (list class (list string) 'make-string))
        (sllgen:grammar->string-literals grammar)))))

;;; ****************************************************************

;;; updatable associative tables

;;; table ::= ((symbol . list) ...)


(define sllgen:make-initial-table       ; makes table with all entries
                                        ; initialized to empty
  (lambda (symbols)
    (map list symbols)))

(define sllgen:add-value-to-table!
  (lambda (table key value)
    (let ((pair (assq key table)))
      (if (member value (cdr pair))
        #f
        (begin
          (set-cdr! pair (cons value (cdr pair)))
          #t)))))

(define sllgen:table-lookup
  (lambda (table key)
    (cdr (assq key table))))

(define sllgen:uniq
  (lambda (l)
    (if (null? l) '()
      (let ((z (sllgen:uniq (cdr l))))
        (if (member (car l) z)
          z
          (cons (car l) z))))))

(define sllgen:union
  (lambda (s1 s2)                       ; s1 and s2 already unique
    (if (null? s1) s2
      (if (member (car s1) s2)
        (sllgen:union (cdr s1) s2)
        (cons (car s1) (sllgen:union (cdr s1) s2))))))

;; this is only called with '(), so the eqv? is ok.
(define sllgen:rember
  (lambda (a s)
    (cond
      ((null? s) s)
      ((eqv? a (car s)) (cdr s))
      (else (cons (car s) (sllgen:rember a (cdr s)))))))


(define sllgen:gensym
  (let ((n 0))
    (lambda (s)
      (set! n (+ n 1))
      (let ((s (if (string? s) s (symbol->string s))))
        (string->symbol
          (string-append s (number->string n)))))))


;;; ****************************************************************

;;; a table for keeping the arity of the generated nonterminals for
;;; arbno.

(define sllgen:arbno-table '())

(define sllgen:arbno-initialize-table!
  (lambda ()
    (set! sllgen:arbno-table '())))

(define sllgen:arbno-add-entry!
  (lambda (sym val)
    (set! sllgen:arbno-table
      (cons (cons sym val) sllgen:arbno-table))))

(define sllgen:arbno-assv
  (lambda (ref)
    (assv ref sllgen:arbno-table)))

(define sllgen:non-terminal-table '())

(define sllgen:initialize-non-terminal-table!
  (lambda (productions)
    (set! sllgen:non-terminal-table '())
    (for-each
      (lambda (prod)
        (sllgen:non-terminal-add!
          (sllgen:production->lhs prod)))
      productions)))

(define sllgen:non-terminal-add!
  (lambda (sym)
    (if (not (memv sym sllgen:non-terminal-table))
      (set! sllgen:non-terminal-table
        (cons sym sllgen:non-terminal-table)))))

(define sllgen:non-terminal?
  (lambda (sym)
    (memv sym sllgen:non-terminal-table)))

;;; ****************************************************************

;;; eliminate-arbno.s

;;; replaces (ARBNO lhs) items with new productions

(define sllgen:eliminate-arbnos-from-rhs
  (lambda (rhs k)
    ;; returns to its continuation the new rhs and the list of
    ;; new productions
    (cond
      ((null? rhs)
       (k rhs '()))
      ((sllgen:arbno? (car rhs))
       (let ((new-nonterm (sllgen:gensym
                            (if (symbol? (cadar rhs)) (cadar rhs) 'arbno)))
             (local-rhs (sllgen:arbno->rhs (car rhs))))
         (sllgen:arbno-add-entry!
           new-nonterm
           (sllgen:rhs-data-length local-rhs))
         (sllgen:eliminate-arbnos-from-rhs
           (cdr rhs)
           (lambda (new-rhs new-prods)
             (sllgen:eliminate-arbnos-from-rhs
               local-rhs
               (lambda (new-local-rhs new-local-prods)
                 (k
                   (cons new-nonterm new-rhs)
                   (cons
                     (sllgen:make-production
                       new-nonterm '() (sllgen:emit-list-action))
                     (cons
                       (sllgen:make-production
                         new-nonterm
                         new-local-rhs
                         (sllgen:goto-action new-nonterm))
                       (append new-local-prods new-prods))))))))))
      ((sllgen:separated-list? (car rhs))
       ;; A -> ((sep-list B1 B2 ... C) ...)
       (let* ((local-rhs (sllgen:separated-list->rhs (car rhs)))
              (separator (sllgen:separated-list->separator (car rhs)))
              (seed (if (symbol? local-rhs) local-rhs 'seplist))
              (new-nonterm1 (sllgen:gensym seed))
              (new-nonterm2 (sllgen:gensym seed))
              (new-nonterm3 (sllgen:gensym seed)))
         (sllgen:arbno-add-entry!
           new-nonterm1
           (sllgen:rhs-data-length local-rhs))
         (sllgen:eliminate-arbnos-from-rhs
           (cdr rhs)
           (lambda (new-rhs new-prods)
             (sllgen:eliminate-arbnos-from-rhs
               local-rhs
               (lambda (new-local-rhs new-local-prods)
                 (k
               (cons new-nonterm1 new-rhs) ; A -> (g1 ...)
               (append
                 (list
                   (sllgen:make-production  ; g1  -> e
                     new-nonterm1 '()
                     (sllgen:emit-list-action))
                   (sllgen:make-production  ; g1 -> B1 B2 (goto g3)
                     new-nonterm1
                     new-local-rhs
                     (sllgen:goto-action new-nonterm3))
                   (sllgen:make-production ; g2 -> B1 B2 (goto g3).
                     new-nonterm2
                     new-local-rhs
                     (sllgen:goto-action new-nonterm3))
                   (sllgen:make-production     ; g3 -> e (emit-list)
                     new-nonterm3
                     '() (sllgen:emit-list-action))
                   (sllgen:make-production ; g3 -> C (goto g2)
                     new-nonterm3
                     (list separator)
                     (sllgen:goto-action new-nonterm2)))
                 new-local-prods
                 new-prods))))))))
      (else
        (sllgen:eliminate-arbnos-from-rhs (cdr rhs)
          (lambda (new-rhs new-prods)
            (k (cons (car rhs) new-rhs)
               new-prods)))))))

(define sllgen:eliminate-arbnos-from-production
  (lambda (production)
    ;; returns list of productions
    (sllgen:eliminate-arbnos-from-rhs
      (sllgen:production->rhs production)
      (lambda (new-rhs new-prods)
        (let ((new-production
                (sllgen:make-production
                  (sllgen:production->lhs production)
                  new-rhs
                  (sllgen:production->action production))))
          (cons new-production
            (sllgen:eliminate-arbnos-from-productions new-prods)))))))

(define sllgen:eliminate-arbnos-from-productions
  (lambda (productions)
    (let loop ((productions productions))
      (if (null? productions)
        '()
        (append
          (sllgen:eliminate-arbnos-from-production (car productions))
          (loop (cdr productions)))))))

(define sllgen:rhs-data-length
  (lambda (rhs)
    (let ((report-error
            (lambda (rhs-item msg)
              (sllgen:error 'parser-generation
                "illegal item ~s (~a) in rhs ~s"
                rhs-item msg rhs))))
      (letrec
        ((loop
           (lambda (rhs)
             ;; (eopl:printf "~s~%" rhs)
             (if (null? rhs) 0
               (let ((rhs-item (car rhs))
                     (rest (cdr rhs)))
                 (cond
                   ((and
                      (symbol? rhs-item)
                      (sllgen:non-terminal? rhs-item))
;                    (eopl:printf "found nonterminal~%")
                    (+ 1 (loop rest)))
                   ((symbol? rhs-item)
;                    (eopl:printf "found terminal~%")
                    (+ 1 (loop rest)))
                   ((sllgen:arbno? rhs-item)
;                    (eopl:printf "found arbno~%")
                    (+
                      (loop (sllgen:arbno->rhs rhs-item))
                      (loop rest)))
                    ((sllgen:separated-list? rhs-item)
;                     (eopl:printf "found seplist~%")
                     (+
                       (loop (sllgen:separated-list->rhs rhs-item))
                       (loop rest)))
                    ((string? rhs-item)
;                     (eopl:printf "found string~%")
                     (loop rest))
                    (else
;                      (eopl:printf "found error~%")
                      (report-error rhs-item "unrecognized item"))))))))
        (loop rhs)))))

;;; ****************************************************************

;;; first-and-follow.s

;;; calculate first and follow sets

;;; base conditions:

;;; A -> a ...   => a in first(A)
;;; A -> ()      => nil in first(A)

;;; closure conditions:

;;; A -> (B1 ... Bk c ...) & nil in first(B1)...first(Bk) => c in first(A)
;;; A -> (B1 ... Bk C ...) & nil in first(B1)...first(Bk) & c in first(C) =>
;;;                                                         c in first(A)
;;; A -> (B1 ... Bk) & nil in first(B1)...first(Bk) => nil in first(A)

(define sllgen:first-table
  (lambda (productions)
    (let* ((non-terminals
             (sllgen:uniq (map sllgen:production->lhs productions)))
           (table (sllgen:make-initial-table non-terminals)))
      (letrec
        ((loop
           ;; initialize with the base conditions and return the
           ;; productions to be considered for the closure
           (lambda (productions)
             (cond
               ((null? productions) '())
               ((null? (sllgen:production->rhs (car productions)))
                ;; A -> ()      => nil in first(A)
                (sllgen:add-value-to-table! table
                  (sllgen:production->lhs (car productions))
                  '())
                (loop (cdr productions)))
               ((member (car
                        (sllgen:production->rhs
                          (car productions)))
                       non-terminals)
                ;; this one is for the closure
                (cons (car productions)
                      (loop (cdr productions))))
               (else
                 ;; this one must start with a terminal symbol
                 (sllgen:add-value-to-table! table
                     (sllgen:production->lhs (car productions))
                     (car
                       (sllgen:production->rhs
                         (car productions)))))))))
        (let ((closure-productions (loop productions)))
          (sllgen:iterate-over-first-table table productions
            non-terminals))))))


(define sllgen:iterate-over-first-table
  (lambda (table productions non-terminals)
    (let* ((changed? '**uninitialized**)
           (add-value!
             (lambda (key value)
               (let ((not-there?
                       (sllgen:add-value-to-table! table key value)))
                 (set! changed? (or changed? not-there?)))))
           (first (lambda (key) (sllgen:table-lookup table key))))
      (letrec
        ((rhs-loop
           (lambda (lhs rhs)
             ;; assume everything in the rhs up to this point has () in
             ;; its first set
             (cond
               ((null? rhs)
                ;; A -> (B1 ... Bk) & nil in first(B1)...first(Bk) =>
                ;; nil in first(A)
                (add-value! lhs '()))
               ;; A -> (B1 ... Bk C ...) & nil in first(B1)...first(Bk)
               ((member (car rhs) non-terminals)
                (for-each
                  (lambda (sym)
                    (if (not (null? sym))
                      ;; & c in first(C) => c in first(A)
                      (add-value! lhs sym)
                      ;; e in first(C) -- continue to search down rhs
                      (rhs-loop lhs (cdr rhs))))
                  (first (car rhs))))
               (else
                 ;; A -> (B1 ... Bk c ...) & nil in
                 ;; first(B1)...first(Bk) => c in first(A)
                 (add-value! lhs (car rhs))))))
         (main-loop
           (lambda ()
             (set! changed? #f)
             (for-each
               (lambda (production)
                 (rhs-loop
                   (sllgen:production->lhs production)
                   (sllgen:production->rhs production)))
               productions)
             (if changed?
               (main-loop)
               table))))
         (main-loop)))))

(define sllgen:first-of-list
  (lambda (first-table non-terminals items)
    (let ((get-nonterminal
            (lambda (item)
              (cond
                ((member item non-terminals) item)
                ((symbol? item) #f)
                ((string? item) #f)
                ((eq? (car item) 'goto) (cadr item))
                (else #f)))))
      (letrec
        ((loop (lambda (items)
                 (cond
                   ((null? items) '(()))                 ; ans = {e}
                   ((get-nonterminal (car items)) =>
                    (lambda (nonterminal)
                      (let ((these
                              (sllgen:table-lookup first-table nonterminal)))
                        (if (member '() these)
                           (let ((others (loop (cdr items))))
                             (let inner ((these these))
                               (cond
                                 ((null? these) others)
                                 ((null? (car these))
                                  (inner (cdr these)))
                                 ((member (car these) others)
                                  (inner (cdr these)))
                                 (else
                                   (cons (car these)
                                        (inner (cdr these)))))))
                           these))))
                   (else (list (car items)))))))
        (loop items)))))

(define sllgen:follow-table
  (lambda (start-symbol productions first-table)
    (let* ((non-terminals
             (sllgen:uniq (map sllgen:production->lhs productions)))
           (table (sllgen:make-initial-table non-terminals))
           (changed? '**uninitialized**)
           (sllgen:add-value!
             (lambda (key value)
               (let ((not-there?
                       (sllgen:add-value-to-table! table key value)))
                 (set! changed? (or changed? not-there?)))))
           ;; closure-rules ::= ((a b) ...) means follow(a) \subset
           ;; follow(b)
           (closure-rules '())
           (get-nonterminal
            (lambda (item)
              (cond
                ((member item non-terminals) item)
                (else #f)))))
      (sllgen:add-value! start-symbol 'end-marker)
      (letrec
        ((init-loop
           ;; loops through productions once, adding starting values
           ;; to follow-table and other productions to closure-rules
           (lambda (productions)
             (if (null? productions)
               #t
               (let* ((production (car productions))
                      (lhs (sllgen:production->lhs production))
                      (rhs (sllgen:production->rhs production))
                      (action (sllgen:production->action production)))
                 (rhs-loop
                   lhs
                   (append rhs ;; add back the goto as a nonterminal
                     (if (and (pair? action) (eq? (car action) 'goto))
                        (list (cadr action))
                        '())))
                 (init-loop (cdr productions))))))
         (rhs-loop
           (lambda (lhs rhs)
             ;; (eopl:printf "rhs-loop lhs=~s rhs=~s~%" lhs rhs)
             (cond
               ((null? rhs) #t)
               ((get-nonterminal (car rhs)) =>
                (lambda (nonterminal)
                ;; we've found a nonterminal.  What's it followed by?
                  (let* ((rest (cdr rhs))
                         (first-of-rest
                           (sllgen:first-of-list
                             first-table non-terminals rest)))
                    (for-each
                      (lambda (sym)
                        (if (not (null? sym))
                           ;; A -> (... B C ...) => first(C...) \subset follow(B)
                           (sllgen:add-value! nonterminal sym)
                           ;; A -> (... B C ...) & e \in first(C ...) =>
                           ;; follow(A) \subset follow (B)
                           (begin
                             (set! closure-rules
                               (cons (list lhs nonterminal)
                                    closure-rules))
                             ;; (eopl:printf "~s~%" (list lhs nonterminal))
                             )))
                      first-of-rest))
                ;; now keep looking
                  (rhs-loop lhs (cdr rhs))))
               (else
                 ;; this one's not a non-terminal.  Keep looking.
                 (rhs-loop lhs (cdr rhs))))))
         (closure-loop
           (lambda ()
             (set! changed? #f)
             (for-each
               (lambda (rule)
                 (let ((a (car rule))
                       (b (cadr rule)))
                   ;; follow(a) \subset follow(b)
                   (for-each
                     (lambda (sym)
                       (sllgen:add-value! b sym))
                     (sllgen:table-lookup table a))))
               closure-rules)
             (if changed?
               (closure-loop)
               table))))
        (init-loop productions)
;       (sllgen:pretty-print closure-rules)
        (closure-loop)))))


;;; ****************************************************************

;;; gen-table.s

;;; gen-table.s  take list of productions, first and follow tables,
;;; and generate parsing table

;;; table ::= ((non-terminal (list-of-items action ...)....) ...)

;;; the list of items is the first(rhs) for each production (or
;;; follow(lhs) if the production is empty.  We should probably check
;;; to see that these are non-intersecting, but we probably won't on
;;; this pass.

;;; First thing to do: collect all the productions for a given
;;; non-terminal.  This gives data structure of the form

;;; ((lhs production ...) ...)

;;; We'll do this using updatable tables.

(define sllgen:group-productions
  (lambda (productions)
    (let* ((non-terminals
             (sllgen:uniq (map sllgen:production->lhs productions)))
           (table (sllgen:make-initial-table non-terminals)))
      (for-each
        (lambda (production)
          (let
            ((lhs (sllgen:production->lhs production)))
            (sllgen:add-value-to-table! table lhs production)))
        productions)
      table)))

;; this one uses the list structure of tables.  [Watch out]

(define sllgen:productions->parsing-table
  (lambda (productions first-table follow-table)
    (let ((non-terminals
            (sllgen:uniq (map sllgen:production->lhs productions)))
          (table (sllgen:group-productions productions)))
      (map
        (lambda (table-entry)
          (sllgen:make-parse-table-non-terminal-entry
            (car table-entry)
            (map
              (lambda (production)
                (sllgen:make-parse-table-production-entry
                  production non-terminals first-table follow-table))
              (cdr table-entry))))
        table))))

(define sllgen:make-parse-table-non-terminal-entry
  (lambda (lhs entries)
    (cons lhs entries)))

(define sllgen:make-parse-table-production-entry
  (lambda (production non-terminals first-table follow-table)
    (let* ((rhs (sllgen:production->rhs production))
           (first-of-rhs (sllgen:first-of-list
                           first-table non-terminals
                           (sllgen:production->rhs production)))
           (steering-items
             (if (member '() first-of-rhs)
               (sllgen:union
                 (sllgen:table-lookup
                   follow-table
                   (sllgen:production->lhs production))
                 (sllgen:rember '() first-of-rhs))
               first-of-rhs)))
      (cons steering-items
            (sllgen:make-parse-table-rhs-entry
              non-terminals
              (sllgen:production->rhs production)
              (sllgen:production->action production))))))

(define sllgen:make-parse-table-rhs-entry
  (lambda (non-terminals rhs action)
    (let loop ((rhs rhs))
      (cond
        ((null? rhs)
         ;; at end -- emit reduce action or emit-list action
         (if (symbol? action)
            ;; symbols become "reduce",
            ;; (emit-list) and (goto nt) stay the same
            (list (list 'reduce action))
            (list action)))
        ((sllgen:arbno-assv (car rhs)) =>
         (lambda (pair)                 ; (cdr pair) is the count for
                                        ; the arbno
           (cons
             (list 'arbno (car rhs) (cdr pair))
             (loop (cdr rhs)))))
        ((member (car rhs) non-terminals)
         (cons (list 'non-term (car rhs))
               (loop (cdr rhs))))
        ((symbol? (car rhs))
         (cons (list 'term (car rhs))
                (loop (cdr rhs))))
        ((string? (car rhs))
         (cons (list 'string (car rhs))
               (loop (cdr rhs))))
        (else
          (sllgen:error 'parser-generation
            "unknown rhs entry ~s"
            (car rhs)))))))

;;; ****************************************************************

;;; check-table.s

;;; take a parse table and check for conflicts

;;; table ::= ((non-terminal (list-of-items action ...)....) ...)

(define sllgen:check-table
  (lambda (table)
    (for-each sllgen:check-productions table)))

(define sllgen:check-productions
  (lambda (non-terminal-entry)
    (let ((non-terminal (car non-terminal-entry))
          (productions (cdr non-terminal-entry)))
      ;; see if the list-of-items are pairwise disjoint
      (let loop ((productions productions))
        (if (null? productions)
          #t                            ; no more to check
          (let ((this-production (car productions))
                (other-productions (cdr productions)))
            ;; check this production
            (for-each
              (lambda (class)
                (let inner ((others other-productions))
                  (cond
                    ((null? others) #t)
                    ;; memq changed to member Tue Nov 16 14:26:32
                    ;; 1999, since class could be a string.
                    ((member class (car (car others)))
                     (sllgen:error 'parser-generation
                       "~%Grammar not LL(1): Shift conflict detected for class ~s in nonterminal ~s:~%~s~%~s~%"
                       class non-terminal this-production (car others)))
                    (else (inner (cdr others))))))
              (car this-production))
            ;; and check the others
            (loop other-productions)))))))


;;; ****************************************************************

;;; scan.scm

;;; Scanner based on regexps and longest-match property

;; new version using proper lookahead in sllgen:scanner-inner-loop
;; Tue Dec 01 11:42:53 1998

;;; External syntax of scanner:

;;; scanner ::= (init-state ...)
;;; init-state ::= (classname (regexp ...) action-opcode)
;;; regexp = etester | (or regexp ...) | (arbno regexp)
;;;        | (concat regexp ...)
;;; etester ::= string | LETTER | DIGIT | WHITESPACE | ANY | (NOT char)

;; top level stream transducer:

(define sllgen:make-scanner
  (lambda (init-states)
    (let ((start-states (sllgen:parse-scanner-spec init-states)))
      (lambda (input-stream)
        (sllgen:scanner-outer-loop start-states input-stream)))))

;;; Conversion of external to internal rep

(define sllgen:parse-scanner-spec
  (lambda (init-states)
    (map sllgen:parse-init-state init-states)))

(define sllgen:parse-init-state
  (lambda (init-state)
    (sllgen:check-syntax-init-state init-state)
    (let ((classname (car init-state))
          (regexps (cadr init-state))
          (opcode (caddr init-state)))
      (sllgen:make-local-state
        (map sllgen:parse-regexp regexps)
        (cons opcode classname)))))

(define sllgen:check-syntax-init-state
  (lambda (v)
    (or
      (and
        (list? v)
        (= (length v) 3)
        (symbol? (car v))
        (list? (cadr v))
        (symbol? (caddr v))
        (member (caddr v) sllgen:action-preference-list))
      (sllgen:error 'scanner-generation "bad scanner item ~s" v))))

(define sllgen:parse-regexp
  (lambda (regexp)
    (cond
      ((char? regexp) (sllgen:make-tester-regexp regexp))
      ((string? regexp) (sllgen:string->regexp regexp))
      ((symbol? regexp) (sllgen:symbol->regexp regexp))
      ((and (pair? regexp) (symbol? (car regexp)))
       (case (car regexp)
         ((or)
          (sllgen:make-or-regexp (map sllgen:parse-regexp (cdr regexp))))
         ((concat)
          (sllgen:make-concat-regexp (map sllgen:parse-regexp (cdr regexp))))
         ((arbno)
          (and
            (or (pair? (cdr regexp))
              (sllgen:error 'scanner-generation "bad regexp ~s" regexp))
            (sllgen:make-arbno-regexp (sllgen:parse-regexp (cadr regexp)))))
         ((not) (and
                  (or (and (pair? (cdr regexp))
                        (char? (cadr regexp)))
                    (sllgen:error 'sllgen:parse-regexp "bad regexp ~s" regexp))
                  (sllgen:make-tester-regexp regexp)))))
      (else (sllgen:error 'scanner-generation "bad regexp ~s" regexp)))))

(define sllgen:string->regexp
  (lambda (string)
    (sllgen:make-concat-regexp
     (map sllgen:make-tester-regexp
      (map sllgen:make-char-tester (string->list string))))))

(define sllgen:symbol->regexp
  (lambda (sym)
    (if (member sym sllgen:tester-symbol-list)
       (sllgen:make-tester-regexp sym)
       (sllgen:error 'scanner-generation "unknown tester ~s" sym))))

;;; regexps
;;; regexp = tester | (or regexp ...) | (arbno regexp)
;;;        | (concat regexp ...)


; (define-datatype regexp
;   (tester-regexp sllgen:tester?)
;   (or-regexp (list-of regexp?))
;   (arbno-regexp regexp?)
;   (concat-regexp (list-of regexp?)))

(define sllgen:make-tester-regexp (lambda (x) x))
(define sllgen:make-or-regexp (lambda (res) (cons 'or res)))
(define sllgen:make-arbno-regexp (lambda (re) (list 'arbno re)))
(define sllgen:make-concat-regexp (lambda (rs) (cons 'concat rs)))

(define sllgen:tester-regexp?
  (lambda (x)
    (and (sllgen:tester? x) (lambda (f) (f x)))))

(define sllgen:or-regexp?
  (lambda (x)
    (and (eq? (car x) 'or)
        (lambda (f) (f (cdr x))))))

(define sllgen:arbno-regexp?
  (lambda (x)
    (and (eq? (car x) 'arbno)
        (lambda (f) (f (cadr x))))))

(define sllgen:concat-regexp?
  (lambda (x)
    (and (eq? (car x) 'concat)
        (lambda (f) (f (cdr x))))))

;; (sllgen:select-variant obj selector1 receiver1 ... [err-thunk])

(define sllgen:select-variant
  (lambda (obj . alts)
    (let loop ((alts alts))
      (cond
        ((null? alts)
         (sllgen:error 'sllgen:select-variant
           "~%Internal error: nothing matched ~a" obj))
        ((null? (cdr alts)) ((car alts)))
        (((car alts) obj) => (lambda (f) (f (cadr alts))))
        (else (loop (cddr alts)))))))


(define sllgen:unparse-regexp                  ; deals with regexps or actions
  (lambda (regexp)
    (if (sllgen:action? regexp)
       regexp
       (sllgen:select-variant regexp
         sllgen:tester-regexp?
         (lambda (tester) tester)
         sllgen:arbno-regexp?
         (lambda (regexp)
           (list 'arbno (sllgen:unparse-regexp regexp)))
         sllgen:concat-regexp?
         (lambda (regexps)
           (cons 'concat (map sllgen:unparse-regexp regexps)))
         sllgen:or-regexp?
         (lambda (regexps)
           (cons 'or (map sllgen:unparse-regexp regexps)))))))

;;; testers
;;; tester ::= char | LETTER | DIGIT | ANY | WHITESPACE | (NOT char)

(define sllgen:tester-symbol-list '(letter digit any whitespace))

(define sllgen:apply-tester
  (lambda (tester ch)
    (cond
      ((char? tester) (char=? tester ch))
      ((symbol? tester)
        (case tester
          ((whitespace) (char-whitespace? ch))
          ((letter) (char-alphabetic? ch))
          ((digit) (char-numeric? ch))
          ((any) #t)                    ; ELSE is not really a tester
          (else (sllgen:error 'sllgen:apply-tester
                  "~%Internal error: unknown tester ~s" tester))))
      ((eq? (car tester) 'not)
       (not (char=? (cadr tester) ch)))
      (else (sllgen:error 'sllgen:apply-tester
              "~%Internal error: unknown tester ~s"
              tester)))))

(define sllgen:make-char-tester
  (lambda (char)
    (and (or (char? char)
            (sllgen:error 'scanner-generation "illegal character ~s" char))
      char)))

(define sllgen:tester?
  (lambda (v)
    (or (char? v)
       (member v sllgen:tester-symbol-list)
       (and (pair? v)
         (eq? (car v) 'not)
         (pair? (cdr v))
         (char? (cadr v))))))


;;; actions
;;; action        ::= (action-opcode . classname)
;;; action-opcode :: = skip | symbol | number | string

;;; make-symbol, make-number, and make-string are supported
;;; alternates, but are deprecated.

;;; the classname becomes the the name of token.

;; if multiple actions are possible, do the one that appears here
;; first.  make-string is first, so literal strings trump identifiers.

;; (define sllgen:action-preference-list    ;暂时注释下面的
;;   '(make-string make-symbol make-number skip))

(define sllgen:action-preference-list ;和上面的重名了,加个long 2025年7月28日10:25:03
  '(string make-string symbol make-symbol number make-number skip))

(define sllgen:find-preferred-action
  (lambda (action-opcodes)
    (let loop ((preferences sllgen:action-preference-list))
      (cond
        ((null? preferences)
         (sllgen:error 'scanning "~%No known actions in ~s"
           action-opcodes))
        ((member (car preferences) action-opcodes)
         (car preferences))
        (else (loop (cdr preferences)))))))

(define sllgen:is-all-skip?
  (lambda (actions)
    (let ((opcode  (sllgen:find-preferred-action (map car actions))))
      (eq? opcode 'skip))))

(define sllgen:cook-token
  (lambda (buffer actions loc)
    (let* ((opcode (sllgen:find-preferred-action (map car actions)))
           (classname (cdr (assq opcode actions))))
      (case opcode
        ((skip) (sllgen:error 'sllgen:cook-token
                  "~%Internal error: skip should have been handled earlier ~s"
                  actions))
        ((make-symbol symbol)
         (sllgen:make-token classname
           (string->symbol (list->string (reverse buffer)))
           loc))
        ((make-number number)
         (sllgen:make-token classname
           (string->number (list->string (reverse buffer)))
           loc))
        ((make-string string)
         (sllgen:make-token classname
           (list->string (reverse buffer))
           loc))
        (else
          (sllgen:error 'scanning
            "~%Unknown opcode selected from action list ~s"
            actions))))))

; (define sllgen:cook-token
;   (lambda (buffer actions loc)
;     (let* ((opcode (sllgen:find-preferred-action (map car actions)))
;            ;; (classname (cdr (assq opcode actions)))
;            )
;       (case opcode
;         ((skip) (sllgen:error 'sllgen:cook-token
;                   "~%Internal error: skip should have been handled earlier ~s"
;                   actions))
;         ((make-symbol identifier)
;          (sllgen:make-token 'identifier
;            (string->symbol (list->string (reverse buffer)))
;            loc))
;         ((make-number number)
;          (sllgen:make-token 'number
;            (string->number (list->string (reverse buffer)))
;            loc))
;         ((make-string string)
;          (sllgen:make-token 'string
;            (list->string (reverse buffer))
;            loc))
;         (else
;           (sllgen:error 'scanning
;             "~%Unknown opcode selected from action list ~s"
;             actions))))))

(define sllgen:action?
  (lambda (action)
    (and
      (pair? action)
      (member (car action) sllgen:action-preference-list)
      (symbol? (cdr action)))))

;; tokens

; (define-record token (symbol? (lambda (v) #t)))
;; (define sllgen:make-token list)  ;1530行还有一个

;;; localstate = regexp* x action

; (define-record local-state ((list-of regexp?) sllgen:action?))

(define sllgen:make-local-state
  (lambda (regexps action)
    (append regexps (list action))))

;; k = (actions * newstates * char * stream) -> val
(define sllgen:scanner-inner-loop
  (lambda (local-states stream k)
    (let ((actions '())
          (newstates '())
          (char '())
          (eos-found? #f))              ; do we need to return this too?
      ;(eopl:printf "initializing sllgen:scanner-inner-loop~%")
      (let loop ((local-states local-states)) ; local-states
;         '(begin
;            (eopl:printf "sllgen:scanner-inner-loop char = ~s actions=~s local-states =~%"
;              char actions)
;            (for-each
;              (lambda (local-state)
;                (sllgen:pretty-print (map sllgen:unparse-regexp local-state)))
;              local-states)
;            (eopl:printf "newstates = ~%")
;            (for-each
;              (lambda (local-state)
;                (sllgen:pretty-print (map sllgen:unparse-regexp local-state)))
;              newstates))
       (if (null? local-states)
          ;; no more states to consider
          (begin
;             '(eopl:printf
;               "sllgen:scanner-inner-loop returning with actions = ~s char = ~s newstates = ~%"
;               actions char)
;             '(for-each
;               (lambda (local-state)
;                 (sllgen:pretty-print (map sllgen:unparse-regexp local-state)))
;               newstates)
            (k actions newstates char stream))
          (let ((state        (car local-states)))
            ;           (eopl:printf "first state:~%")
            ;           (sllgen:pretty-print state)
            (cond
              ((sllgen:action? (car state))    ; state should never be null
               ;; recommend accepting what's in the buffer
               (set! actions (cons (car state) actions))
               (loop (cdr local-states)))
              ((sllgen:tester-regexp? (car state))
               =>
               (sllgen:xapply
                 (lambda (tester)
                   ;; get a character if one hasn't been gotten and we
                   ;; haven't discovered eos.
                   (if (and (null? char) (not eos-found?))
                      (sllgen:char-stream-get! stream
                        (lambda (ch1)
                          '(printf "read character ~s~%" ch1)
                          (set! char ch1))
                        (lambda ()
                          (set! eos-found? #t))))
                   '(printf "applying tester ~s to ~s~%" tester char)
                   (if (and (not (null? char))
                           (sllgen:apply-tester tester char))
                      ;; passed the test -- shift is possible
                      (set! newstates (cons (cdr state) newstates)))
                   ;; either way, continue with the other local-states
                   (loop (cdr local-states)))))
              ((sllgen:or-regexp? (car state))
               =>
               (sllgen:xapply
                 (lambda (alternatives)
                   ;; its ((or alts) regexps action)
                   (loop (append
                           (map (lambda (alt) (cons alt (cdr state)))
                               alternatives)
                           (cdr local-states))))))
              ((sllgen:arbno-regexp? (car state))
               =>
               (sllgen:xapply
                 (lambda (regexp1)
                   ;; it's ((arbno regexp1) regexps action)
                   ;; so its either (regexps action) or
                   ;; (regexp1 (arbno regexp1) regexps action)
                   (loop
                     (append
                       (list
                         (cdr state)    ; 0 occurrences
                         (cons regexp1 state) ; >= 1 occurrences
                         )
                       (cdr local-states))))))
              ((sllgen:concat-regexp? (car state))
               =>
               (sllgen:xapply
                 (lambda (sequents)
                   ;; (printf "processing concat: sequents = ~s~%" sequents)
                   (loop
                     (cons
                       (append sequents (cdr state))
                       (cdr local-states)))))))))))))

(define sllgen:xapply (lambda (x) (lambda (y) (y x))))

(define sllgen:scanner-outer-loop
  (lambda (start-states input-stream)   ; -> (token stream), same as before
    (let
      ((states start-states)            ; list of local-states
       (buffer '())                     ; characters accumulated so far
       (success-buffer '())             ; characters for the last
                                        ; candidate token (a sublist
                                        ; of buffer)
       (actions '())                    ; actions we might perform on succ-buff
       (stream input-stream)
       )
      (letrec
        ((process-stream
           (lambda ()
             (sllgen:scanner-inner-loop states stream
               (lambda (new-actions new-states char new-stream)
                 (if (not (null? new-actions))
                   ;; ok, the current buffer is a candidate token
                   (begin
                     (set! success-buffer buffer)
                     ;; (printf "success-buffer =~s~%" success-buffer)
                     (set! actions new-actions))
                   ;; otherwise leave success-buffer and actions alone
                   )
                 (if (null? new-states)
                   ;; we are definitely at the end of this token
                   (process-buffer char new-stream)
                   ;; there might be more -- absorb another character and
                   ;; consider what to do next.
                   (begin
                     (set! buffer (cons char buffer))
                     (set! stream  new-stream)
                     (set! states new-states)
                     (process-stream)))))))
         (process-buffer                ; can't absorb any more chars,
                                        ; better make do with what we have.
           (lambda (char new-stream)
             ;; first, push the lookahead character back on the
             ;; stream.
             (if (not (null? char))
               (sllgen:char-stream-push-back! char new-stream))
             (set! stream new-stream)
             (if (null? buffer)
               ;; any characters in the buffer?  If not, the stream
               ;; must have been empty, so return the empty stream.
               sllgen:empty-stream
               ;; otherwise, push back any unused characters into the stream
               (begin
                 (let push-back-loop ()
                   (if (eq? buffer success-buffer)
                     ;; this really is reference equality.
                     #t
                     (begin
                       ;; (eopl:printf "pushing back ~s~%" (car buff))
                       (sllgen:char-stream-push-back! (car buffer) stream)
                       (set! buffer (cdr buffer))
                       (push-back-loop))))
                 ;; next, look at actions.
                 (cond
                   ((null? actions)
                    ;; no actions possible?  Must be a mistake
                    (sllgen:error 'scanning
                      "~%No actions found for ~s" (reverse buffer)))
                   ((sllgen:is-all-skip? actions)
                    ;; If only action is SKIP,
                    ;; then discard buffer and start again.
                    (set! buffer '())
                    (set! success-buffer '())
                    (set! states start-states) ;!
                    (process-stream))
                   ;;    Otherwise, perform action on the success-buffer
                   ;;    and create a token stream.
                   (else
                     (let ((token
                             (sllgen:cook-token
                               success-buffer
                               actions
                               (sllgen:char-stream->location stream))))
                       (sllgen:make-stream 'tag5
                         token
                         (lambda (fcn eos-fcn)
                           ((sllgen:scanner-outer-loop start-states stream)
                            fcn eos-fcn)))))))))))
        ;; start by trying to absorb a character
        (process-stream)))))

;; Watch out for examples like:
;; ("a" | "b" | "c" | "abcdef")  matched against "abc" should produce
;; 3 tokens before reaching eos.

;; tokens

; (define-record token (symbol? (lambda (v) #t)))

(define sllgen:make-token list)
(define sllgen:token->class car)
(define sllgen:token->data cadr)
(define sllgen:token->location caddr)

;;; streams

;;; (sllgen:stream-get! (sllgen:make-stream tag char stream) fcn eos-fcn) = (fcn char stream)

;;; this is banged, because doing it on some streams may cause a side-effect.
(define sllgen:stream-get!
  (lambda (str fcn eos-fcn)
    (str fcn eos-fcn)))

(define sllgen:empty-stream
  (lambda (fcn eos-fcn)
    (eos-fcn)))

(define sllgen:make-stream
  (lambda (tag char stream)
    ;(eopl:printf "sllgen:make-stream: building stream at ~s with ~s~%" tag char)
    (lambda (fcn eos-fcn)
      ;(eopl:printf "sllgen:make-stream: emitting ~s~%" char)
      (fcn char stream))))

(define sllgen:list->stream
  (lambda (l)
    (if (null? l) sllgen:empty-stream
      (sllgen:make-stream 'sllgen:list->stream (car l) (sllgen:list->stream (cdr l))))))

; ;; brute force for now.
; (define sllgen:string->stream
;   (lambda (string) (sllgen:list->stream (string->list string))))

; ;; this one has state:
; (define sllgen:stdin-char-stream
;   (lambda (fcn eos-fcn)
;     (let ((char (read-char)))
;       (if (eof-object? char)
;         (eos-fcn)
;         (fcn char sllgen:stdin-char-stream)))))

(define sllgen:stream->list
  (lambda (stream)
    (sllgen:stream-get! stream
      (lambda (val stream)
        (cons val (sllgen:stream->list stream)))
      (lambda () '()))))

(define sllgen:constant-stream
  (lambda (val)
    (lambda (fn eos)
      (fn val (sllgen:constant-stream val)))))

;; takes a stream and produces another stream that produces the
;; sentinel instead of an end-of-stream
(define sllgen:stream-add-sentinel
  (lambda (stream sentinel)
    (lambda (fn eos)                    ; here's what to do on a get
      (sllgen:stream-get! stream
        (lambda (val str)
          (fn val (sllgen:stream-add-sentinel str sentinel)))
        (lambda ()
          (fn sentinel (sllgen:constant-stream sentinel)))))))

;; (define sllgen:stream-add-sentinel-via-thunk   ;和下面的版本求值次数不同,可能会有些微区别,暂时注释
;;   (lambda (stream sentinel-fcn)
;;     (lambda (fn eos)                    ; here's what to do on a get
;;       (sllgen:stream-get! stream
;;         (lambda (val str)
;;           (fn val (sllgen:stream-add-sentinel-via-thunk str sentinel-fcn)))
;;         (lambda ()
;;           (fn (sentinel-fcn) (sllgen:constant-stream (sentinel-fcn))))))))

(define sllgen:stream-add-sentinel-via-thunk
  (lambda (stream sentinel-fcn)
    (lambda (fn eos)                    ; here's what to do on a get
      (sllgen:stream-get! stream
        (lambda (val str)
          (fn val (sllgen:stream-add-sentinel-via-thunk str sentinel-fcn)))
        (lambda ()
          ;; when the stream runs out, try this
          (let ((sentinel (sentinel-fcn)))
;            (eopl:printf "~s~%" sentinel)
            (fn sentinel (sllgen:constant-stream sentinel))))))))

; no longer used
; (define sllgen:stream-get
;   (lambda (stream fcn)
;     (sllgen:stream-get! stream fcn
;       (lambda ()
;         (sllgen:error 'sllgen:stream-get
;           "internal error: old streams aren't supposed to produce eos")))))


;;; ****************************************************************

;;; imperative character streams Tue Apr 11 12:09:32 2000

;;; interface:

;;; sllgen:string->stream  : string -> charstream
;;; sllgen:stdin-char-stream : () -> charstream

;;; sllgen:char-stream-get! : !charstream * (char -> ans) * (() -> ans)
;;;                             -> ans
;;;                           [modifies charstream]
;;; sllgen:char-stream-push-back! : char * !charstream -> ()
;;; sllgen:char-stream->location : charstream -> location

;;; for the moment, a location is a line number

;;; we have two kinds of streams-- those built by string->stream and
;;; those built by stdin-char-stream.  We'll use a little OO here.

;;; represent by a vector

;;; [get-fn ; push-back-fn ; location ; other stuff]

(define sllgen:char-stream-get!
  (lambda (cstr sk th)
    ((vector-ref cstr 0) cstr sk th)))

(define sllgen:char-stream-push-back!
  (lambda (ch cstr)
    ((vector-ref cstr 1) ch cstr)))

(define sllgen:char-stream->location
  (lambda (cstr)
    (vector-ref cstr 2)))

(define sllgen:set-location!
  (lambda (vec val)
    (vector-set! vec 2 val)))

;;; for a string-built stream, the other stuff consists of an index
;;; into the string  for the next unread character, and a string.

(define sllgen:string->stream
  (lambda (string)
    (let ((len (string-length string)))
      (vector
        ;; the get! function
        (lambda (vec sk th)
          (let ((index (vector-ref vec 3)))
            (if (>= index len)
              (th)
              (begin
                (vector-set! vec 3 (+ 1 index))
                (let ((ch (string-ref (vector-ref vec 4) index)))
                  (sllgen:set-location! vec
                    (sllgen:increment-location ch
                      (sllgen:char-stream->location vec)))
                  (sk ch))))))
        ;; the push-back function
        (lambda (ch vec)
          (sllgen:set-location! vec
            (sllgen:decrement-location ch
              (sllgen:char-stream->location vec)))
          (vector-set! vec 3 (- (vector-ref vec 3) 1)))
        ;; the location is initially 1
        1
        ;; the index is initially 0
        0
        string                          ;; the string
        ))))


;; (define sllgen:stdin-char-stream   ;暂时注释
;;   (lambda (fcn eos-fcn)
;;     (let ((char (read-char)))
;;       (if (eof-object? char)
;;         (eos-fcn)
;;         (fcn char sllgen:stdin-char-stream)))))

;; for stdin-char-stream, we have
;; [get-fn ; push-back-fn ; location ; push-back stack]

(define sllgen:stdin-char-stream        ; this must be a thunk to reset the
                                        ;  line number
  (lambda ()
    (vector
      ;; the get! fcn
      (lambda (vec sk th)
        (let ((read-back-stack (vector-ref vec 3)))
          (if (null? read-back-stack)
            (let ((char (read-char)))
              (if (eof-object? char)
                (th)
                (begin
                  (sllgen:set-location! vec
                    (sllgen:increment-location char
                      (sllgen:char-stream->location vec)))
                  (sk char))))
            (let ((char (car read-back-stack)))
              (sllgen:set-location! vec
                (sllgen:increment-location char
                  (sllgen:char-stream->location vec)))
              (vector-set! vec 3 (cdr read-back-stack))
              (sk char)))))
      ;; the push back
      (lambda (ch vec)
        (sllgen:set-location! vec
          (sllgen:decrement-location ch
            (sllgen:char-stream->location vec)))
        (vector-set! vec 3 (cons ch (vector-ref vec 3))))
      0                                 ; location is initially 0 to
                                        ;  swallow the initial newline
      '()                               ; push-back is initially empty
      )))

(define sllgen:char-stream->list
  (lambda (cstr)
    (let loop ()
      (sllgen:char-stream-get! cstr
        (lambda (ch) (cons ch (loop)))
        (lambda () '())))))

(define sllgen:char-stream->list2
  (lambda (cstr)
    (let loop ()
      (sllgen:char-stream-get! cstr
        (lambda (ch)
          (cons
            (cons ch (sllgen:char-stream->location cstr))
            (loop)))
        (lambda () '())))))


(define sllgen:increment-location
  (lambda (ch n)
    (if (eqv? ch #\newline) (+ 1 n) n)))

(define sllgen:decrement-location
  (lambda (ch n)
    (if (eqv? ch #\newline) (- n 1) n)))

;;; see tests.s for examples.

;;; ****************************************************************

;;; parse.s

;;; parse.s -- run the generated parser

;;; parsing table is of following form:

;;; table ::= ((non-terminal alternative ...) ...)
;;; alternative ::= (list-of-items action ...)
;;; action ::= (TERM symbol) | (NON-TERM symbol) | (GOTO symbol)
;;;            | (EMIT-LIST) | (REDUCE symbol)

;;; The token register can either contain an token or '() -- the latter
;;; signifying an empty buffer, to be filled when necessary.

; (define-record sllgen:parser-result (tree token stream))

; k = (lambda (tree token stream) ...)
; token may be a token or nil.
(define sllgen:find-production
  (lambda (non-terminal parser buf token stream k)
    (if (null? token)
      (sllgen:stream-get! stream
        (lambda (next-token next-stream)
;        '(eopl:printf "find-production: filling token buffer with ~s~%" token)
          (set! token next-token)
          (set! stream next-stream))
        (lambda ()
          (sllgen:error 'sllgen:find-production
            "~%Internal error: shouldn't run off end of stream"))))
;    '(eopl:printf "sllgen:find-production: nonterminal = ~s token = ~s~%"
;       non-terminal token)
    (let loop
      ((alternatives (cdr (assq non-terminal parser))))
      (cond
        ((null? alternatives)
         (sllgen:error 'parsing
           "at line ~s~%Nonterminal <~s> can't begin with ~s ~s"
           (sllgen:token->location token)
           non-terminal
           (sllgen:token->class token)
           (sllgen:token->data token)))
        ((member (sllgen:token->class token) (car (car alternatives)))
;         '(eopl:printf "sllgen:find-production: using ~s~%~%"
;            (cdr (car alternatives)))
         (sllgen:apply-actions non-terminal (cdr (car alternatives))
           parser buf token stream k))
        ((and (string? (sllgen:token->data token))
           (member (sllgen:token->data token) (car (car alternatives))))
         (sllgen:apply-actions non-terminal (cdr (car alternatives))
           parser buf token stream k))
        (else (loop (cdr alternatives)))))))

(define sllgen:apply-actions
  (lambda (lhs action-list parser buf token stream k)
    (let loop ((actions action-list)
               (buf buf)
               (token token)
               (stream stream))
      (let ((fill-token!                ; fill-token! is a macro in mzscheme
              (lambda ()
                (if (null? token)
                  (sllgen:stream-get! stream
                    (lambda (next-token next-stream)
                      (set! token next-token)
                      (set! stream next-stream))
                    (lambda ()
                      (sllgen:error 'sllgen:apply-actions
                        "~%Internal error: shouldn't run off end of stream"
                        ))))))
            (report-error
              (lambda (target)
                (sllgen:error 'parsing
                  "at line ~s~%Looking for ~s, found ~s ~s in production~%~s"
                  (sllgen:token->location token)
                  target
                  (sllgen:token->class token)
                  (sllgen:token->data token)
                  action-list))))
        (let ((action      (car actions))
              (next-action (cdr actions)))
;         (eopl:printf "actions = ~s~%token = ~s buf = ~s~%~%" actions token buf)
          (case (car action)
            ((term)
             (fill-token!)
             (let ((class (cadr action)))
               (if (eq? (sllgen:token->class token) class)
                 ;; ok, this matches, proceed, but don't get next token --
                 ;; after all, this might be the last one.
                 (loop next-action
                   (cons (sllgen:token->data token) buf)
                   '()                  ; token register is now empty
                   stream)
                 ;; nope, fail.
                 (report-error class))))
            ((string)
             (let ((the-string (cadr action)))
               (fill-token!)
               (if (and
                     (not (eq? (sllgen:token->class token) 'end-marker))
                     (string? (sllgen:token->data token))
                     (string=? (sllgen:token->data token) the-string))
                 (loop next-action buf '() stream)
                 ;; nope, fail.
                 (report-error the-string))))
            ((non-term)
             (let ((non-terminal (cadr action)))
               (sllgen:find-production non-terminal parser
                 '() token stream
                 (lambda (tree token stream)
                   (loop next-action (cons tree buf) token stream)))))
            ((arbno)
             (let ((non-terminal (cadr action))
                   (count       (caddr action)))
               (sllgen:find-production non-terminal parser
                 '() token stream
                 (lambda (trees token stream)
                   (loop next-action
                     (sllgen:unzip-buffer trees count buf)
                     token stream)))))

            ((goto)
             (let ((non-terminal (cadr action)))
               (sllgen:find-production non-terminal parser buf token
                 stream k)))
            ((emit-list)
             (k buf token stream))
            ((reduce)
             (let ((opcode (cadr action)))
               (k
                                        ;               (apply (make-record-from-name opcode)
                                        ;                      (reverse buf))
                 (sllgen:apply-reduction lhs opcode (reverse buf))
                 token
                 stream)))
            (else
              (sllgen:error 'sllgen:apply-actions
                "~%Internal error: unknown instruction ~s"
                action))))))))

(define sllgen:unzip-buffer
  (lambda (trees n buf)
    (let ((ans (let consloop ((n n))
                 (if (zero? n) buf (cons '() (consloop (- n 1)))))))
    (let loop ((trees trees)
               (ptr ans)
               (ctr n))
;     (eopl:printf "ctr = ~s trees = ~s~%" ctr trees)
      (cond
        ((null? trees) ans)
        ((zero? ctr) (loop trees ans n))
        (else
          (set-car! ptr (cons (car trees) (car ptr)))
          (loop (cdr trees) (cdr ptr) (- ctr 1))))))))

;;; next are several alternative definitions for sllgen:apply-reduction

;; just a stub.
(define sllgen:apply-reduction-stub
  (lambda (lhs prod-name args)
    (sllgen:error 'sllgen-configuration "need to set sllgen:apply-reduction")))

;; just construct a list
(define sllgen:generic-node-constructor
  (lambda (lhs production-name args)
    (cons production-name args)))

;; this is the default, since it lets sllgen stand alone.
(define sllgen:apply-reduction sllgen:generic-node-constructor)

;; here are alternative bindings:

;; Alas, define-datatype:constructor-back-door no longer exists.  This
;; was supposed to be a way to get at the constructor from its name,
;; so that we could write sllgen without knowing the representation of
;; trees used by define-datatype.  But (alas!) it no longer exists.
;; Maybe it will be put back in some future version of d-d.
;; --mw Mon Apr 24 15:07:20 2000
;
;; look up the constructor in the define-datatype table
; (define sllgen:apply-datatype-backdoor
;   (lambda (lhs variant-name args)
;     (apply (define-datatype:constructor-back-door lhs variant-name)
;       args)))

(define sllgen:eval-reduction
  (lambda (lhs opcode args)
    (apply (eval opcode (interaction-environment))
      args)))

;; and procedures to install them:

(define sllgen:use-generic-node-constructor
  (lambda ()
    (set! sllgen:apply-reduction sllgen:generic-node-constructor)))

; (define sllgen:use-datatype-backdoor
;   (lambda ()
;     (set! sllgen:apply-reduction sllgen:apply-datatype-backdoor)))

(define sllgen:use-eval-reduction
  (lambda ()
    (set! sllgen:apply-reduction sllgen:eval-reduction)))


;; temporary
; (define make-record-from-name
;   (lambda (sym)
;     (lambda args
;       (cons sym args))))


;;; ****************************************************************

;; go through a grammar and generate the appropriate define-datatypes.

;;; define-datatype syntax is:
;;;(define-datatype Type-name Predicate-name
;;;  (Variant-name (Field-name Predicate-exp) ...) ...)


(define sllgen:build-define-datatype-definitions
  (lambda (scanner-spec grammar)
    (let* ((scanner-datatypes-alist
             (sllgen:make-scanner-datatypes-alist scanner-spec))
           (non-terminals
             (sllgen:uniq (map sllgen:production->lhs
                              (sllgen:grammar->productions grammar))))
           (datatype-table (sllgen:make-initial-table non-terminals)))
      ;; for each production, add an entry to the table.  Each entry is
      ;; (prod-name . datatype-list)
      (for-each
        (lambda (production)
          (sllgen:add-value-to-table! datatype-table
            (sllgen:production->lhs production)
            (cons
              (sllgen:production->action production)
              (sllgen:make-rhs-datatype-list
                (sllgen:production->rhs production)
                non-terminals
                scanner-datatypes-alist))))
        (sllgen:grammar->productions grammar))
      ;; now generate the list of datatypes for each table entry
      (map
        (lambda (non-terminal)
          (sllgen:make-datatype-definition non-terminal
            (sllgen:table-lookup datatype-table non-terminal)))
        non-terminals))))


(define sllgen:make-scanner-datatypes-alist
  (lambda (init-states)
    (let
      ((opcode-type-alist
         '((make-symbol . symbol?)
           (symbol . symbol?)
           (make-string . string?)
           (string . string?)
           (make-number . number?)
           (number . number?))))
      (let loop ((init-states init-states))
        (if (null? init-states) '()
          (let ((init-state  (car init-states))
                (init-states (cdr init-states)))
            (let ((class (car init-state))
                  (type-pair (assq (sllgen:last init-state) opcode-type-alist)))
              (if (not type-pair)
                 (loop init-states)
                 (cons (cons class (cdr type-pair))
                      (loop init-states))))))))))

(define sllgen:last
  (lambda (x)
    (and
      (or (pair? x)
         (sllgen:error 'sllgen:last "~%Can't take last of non-pair ~s" x))
      (if (null? (cdr x))
         (car x)
         (sllgen:last (cdr x))))))

;;; rhs ::= (rhs-item ...)
;;;
;;; rhs-item ::= string | symbol | (ARBNO . rhs) | (SEPARATED-LIST rhs
;;;                                                         token)

(define sllgen:make-rhs-datatype-list
  (lambda (rhs non-terminals scanner-datatypes-alist)
    (let ((report-error
            (lambda (rhs-item msg)
              (sllgen:error 'defining-datatypes
                "~%Illegal item ~s (~a) in rhs ~s"
                rhs-item msg rhs))))
      (let loop ((rhs rhs))
        (if (null? rhs) '()
          (let ((rhs-item (car rhs))
                (rest (cdr rhs)))
            (cond
              ((and (symbol? rhs-item) (member rhs-item non-terminals))
               ;; this is a non-terminal
               (cons (sllgen:non-terminal->tester-name rhs-item)
                    (loop rest)))
              ((symbol? rhs-item)
               ;; this must be a terminal symbol
               (let ((type (assq rhs-item scanner-datatypes-alist)))
                 (if type
                    (cons (cdr type) (loop rest))
                    (report-error rhs-item "unknown symbol"))))
              ((sllgen:arbno? rhs-item)
               (append
                 (map
                   (lambda (x) (list 'list-of x))
                   (loop (sllgen:arbno->rhs rhs-item)))
                 (loop rest)))
              ((sllgen:separated-list? rhs-item)
               (append
                 (map
                   (lambda (x) (list 'list-of x))
                   (loop (sllgen:separated-list->rhs rhs-item)))
                 (loop rest)))
              ((string? rhs-item)
               (loop rest))
              (else (report-error rhs-item "unrecognized item")))))))))

(define sllgen:non-terminal->tester-name
  (lambda (x)
    (string->symbol (string-append (symbol->string x) "?"))))

;; variants are now the same as constructors
(define sllgen:variant->constructor-name
  (lambda (x) x))


(define sllgen:make-datatype-definition
  (lambda (non-terminal entries)
    (let ((tester-name
            (sllgen:non-terminal->tester-name non-terminal))
          (entries
            ;; reverse gets the entries in the same order as the productions
            (map sllgen:make-variant (reverse entries))))
       `(define-datatype ,non-terminal ,tester-name . ,entries))))

(define sllgen:make-variant
  (lambda (entry)
    `(,(car entry)
      . ,(map
           (lambda (pred)
             (list (sllgen:gensym (car entry)) pred))
           (cdr entry)))))

;;; ****************************************************************
;;; error handling
;;; ****************************************************************

(define sllgen:error error)

;;; ****************************************************************
;;; ****************************************************************

;;; sample input  (test-sllgen2.scm)

; (define lex2
;    '((whitespace (whitespace) skip)
;      (comment ("%" (arbno (not #\newline))) skip)
;      (identifier (letter (arbno (or letter digit))) make-symbol)
;      (number (digit (arbno digit)) make-number)))

; (define gram2
;   '((expression
;       (number)
;       lit-exp)
;     (expression
;       (identifier)
;       var-exp)
;     (expression
;       ("let" (separated-list declaration ";") "in" expression)
;       let-exp)
;     (expression
;       ("(" expression (arbno expression) ")")
;       app-exp)
;     (declaration
;       (identifier "=" expression)
;       decl)))

; (define test2 '*)
; (define scan2 '*)

; (define gen2
;   (lambda ()
;     ; if define-datatypes is loaded:
;    ; (sllgen:generate-define-datatypes lex2 gram2)
;     (set! test2
;       (let ((parser (sllgen:make-string-parser lex2 gram2)))
;         (lambda (string)
;           (sllgen:pretty-print (parser string)))))
;     (set! scan2
;       (sllgen:make-string-scanner lex2 gram2))))

; (define rep
;   (lambda ()
;     (sllgen:make-rep-loop "--> " (lambda (x) (sllgen:pretty-print x) #t)
;       (sllgen:make-stream-parser lex2 gram2))))

; (define rsp
;   (lambda ()
;     (sllgen:make-rep-loop "--> " (lambda (x) x)
;       (sllgen:make-stream-scanner lex2 gram2))))


; Welcome to MzScheme version 53, Copyright (c) 1995-98 PLT (Matthew Flatt)
; > (load "sllgen.scm")
; sllgen.scm 2.3.4 Time-stamp: <1998-12-31 15:35:02 Mitch>
; > (load "test-sllgen2.scm")
; > (gen2)
; > (test2 "let x = 3; y=4 in (f x y)")
; (let-exp
;   ((decl x (lit-exp 3)) (decl y (lit-exp 4)))
;   (app-exp (var-exp f) ((var-exp x) (var-exp y))))
; > (rep)
; --> x
; (var-exp x)
; #t
; --> (f y)
; (app-exp (var-exp f) ((var-exp y)))
; #t
; --> user break
; > (sllgen:list-define-datatypes lex2 gram2)
; (define-datatype
;   expression
;   expression?
;   expression-case
;   (lit-exp make-lit-exp (lit-exp39 number?))
;   (var-exp make-var-exp (var-exp40 symbol?))
;   (let-exp
;     make-let-exp
;     (let-exp41 (list-of declaration?))
;     (let-exp42 expression?))
;   (app-exp
;     make-app-exp
;     (app-exp43 expression?)
;     (app-exp44 (list-of expression?))))
; (define-datatype
;   declaration
;   declaration?
;   declaration-case
;   (decl make-decl (decl45 symbol?) (decl46 expression?)))
; >

; sample input  (test-sllgen2.scm)

(define lex2
   '((whitespace (whitespace) skip)
     (comment ("%" (arbno (not #\newline))) skip)
     (identifier (letter (arbno (or letter digit))) make-symbol)
     (number (digit (arbno digit)) make-number)))

(define gram2
  '((expression
      (number)
      lit-exp)
    (expression
      (identifier)
      var-exp)
    (expression
      ("let" (arbno declaration) "in" expression)
      let-exp)
    (expression
      ("mvlet"
        (separated-list  (separated-list identifier ",")
          "=" expression ";") "in" expression)
      lets-exp)
    (expression
      ("(" expression (arbno expression) ")")
      app-exp)
    (declaration
      (identifier "=" expression)
      decl)))

; (sllgen:make-define-datatypes lex2 gram2)

(define show2
  (lambda () (sllgen:list-define-datatypes lex2 gram2)))

(define parse2 '*)

(define gen2
  (lambda () (set! parse2 (sllgen:make-string-parser lex2 gram2))))

(define gram3
  '((expression
      (number)
      lit-exp)
    (expression
      (identifier)
      var-exp)
    (expression
      ("let" (arbno identifier "=" expression) "in" expression)
      let-exp)
    (expression
      ("mvlet" (arbno (arbno identifier) "=" expression) "in" expression)
      mvlet-exp)
    (expression
      ("(" expression (arbno expression) ")")
      app-exp)
    (declaration
      (identifier "=" (arbno expression))
      decl)))

(define show3
  (lambda () (sllgen:list-define-datatypes lex2 gram3)))

(define list3
  (lambda () (sllgen:list-define-datatypes lex2 gram3)))

(define parse3 '*)

(define gen3
  (lambda () (set! parse3 (sllgen:make-string-parser lex2 gram3))))


(define gram4
  '((expression
      ("let" (separated-list (separated-list identifier "," ) "=" expression ";" )
        "in" expression)
      let-exp)
    (expression
      (number)
      lit-exp)))

(define parse4 '*)

(define gen4
  (lambda () (set! parse4 (sllgen:make-string-parser lex2 gram4))))

(define show4
  (lambda () (sllgen:list-define-datatypes lex2 gram4)))
