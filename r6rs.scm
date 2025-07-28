;;; defining eopl fcns in R6RS scheme

(define debug? (make-parameter #f))

(define eopl:printf printf)

(define eopl:pretty-print pretty-print)

(define sllgen:pretty-print          eopl:pretty-print)
(define define-datatype:pretty-print eopl:pretty-print)

(define eopl:error error)
(define eopl:error-stop "eopl:error-stop is purposely undefined")

(define-syntax equal??
  (syntax-rules ()
    ((_ test-exp correct-ans)
     (let ((observed-ans test-exp))
       (if (not (equal? observed-ans correct-ans))
           (printf "~s returned ~s, should have returned ~s~%"
                   'test-exp
                   observed-ans
                   correct-ans))))))
