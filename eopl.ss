(library (eopl eopl)
  (export define-datatype cases
	  sllgen:make-define-datatypes sllgen:make-string-parser)
  (import (chezscheme))
  
  (include "r6rs.scm")
  (include "sllgen.scm")
  (include "define-datatype.scm")
  )
