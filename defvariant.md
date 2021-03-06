
```lisp
(in-package #:defvariant)

```


# Variants in Common Lisp #

This document is the source code as well as the explanation
of the `defvariant` macro that adds the variant datatype 
to Common Lisp.

It is a good example of a non-trivial "macro-generating-macro" so
 anyone interested in macro-programming could benefit from reading this.

An "advanced-beginner" or intermediate level of Common Lisp is required.

**Remark** : a simpler and more pedagogical-minded version of `defvariant` is available at https://github.com/fredokun/defvariant/tree/v0.2_tutorial

## A macro refresher

We begin with a small refresher for macros with a simple although
quite useful macro for inline examples.

The macro can be deactivated so that it becomes totally silent.



```lisp
(defvar *example-enabled* t
  "Parameter for enabling/disabling
the `EXAMPLE` macro. Use NIL in production code.")

```


And the definition follows.



```lisp
(defmacro example (expr arrow expected &key (eq? #'equal) (warn-only nil))
  "Show an evaluation example, useful for documentation and lightweight testing.

   (example `EXPR` => `EXPECTED`) evaluates `EXPR` and compare, wrt. `EQ?`
 (EQUAL by default) to `EXPECTED` and raise an error if inequal.

  Set `WARN-ONLY` to T for warning instead of error.
"
  (if (not *example-enabled*)
      nil ;; synonymous of nil if disabled
      ;; when enabled
      (let ((err-fun (if warn-only #'warn #'error)))
        (if (not (eq arrow '=>))
            (error "Missing => in example expression"))
        (let ((result-var (gensym "result-"))
              (expected-var (gensym "expected-"))
              (expr-var (gensym "expr-")))
          `(let ((,result-var ,expr)
                 (,expr-var (quote ,expr))
                 (,expected-var ,expected))
             (if (funcall ,eq? ,result-var ,expected-var)
                 t
                 (funcall ,err-fun "Failed example:~%  Expression: ~S~%  ==> expected: ~S~%  ==> evaluated: ~S~%"
                          ,expr-var ,expected-var ,result-var)))))))

```


Note that my own style is to write relatively low-level macro-code so that
 the macros presented here do not rely on macro-programming utilies.
 The `gensym`'s are also performed by hand because I like to have nice
macro-expansion informations.

A valid example will simply evaluate to `T`.



```lisp
(example 1 => 1) ;; => T

```


Wherease a failed example will generated an error.
 If the keyword argument `:warn-only` is set to true,
 then only a warning is issued and the forms returns `NIL`.



```lisp
(example 1 => 2 :warn-only t) ;; => NIL

```


    WARNING: Failed example:
      Expression: 1
      ==> expected: 2
      ==> evaluated: 1


Let's go back to our `defvariant` macro.

## The defvariant special form

A `defvariant` expression has the following form:

    (defvariant <variant>
      (<case_1> <case_1_var_1> ... <case_1_var_M_1>)
      (<case_2> <case_2_val_1> ... <case_2_var_M_2>)
      ...
      (<case_N> <case_N_var_1> ... <case_N_var_M_N>))

From this, we should generate :

 1. an abstract structure type for `<variant>` and a concrete structure type for each `<caseI>`, named `<variant>-<caseI>` with supertype `<variant>`  (for `I` from 1 to `N`)
 2. a variant case dispatch function `<variant>-dispatch` and a call wrapper function for each case: `<variant>-<caseI>-call` (for `I` from 1 to `N`)
 3. a `match-<variant>` macro

Our running example will be a variant for binary trees:

    (defvariant btree
      (leaf)
      (node val left right))

## The structure types

It is quite easy to generate the structure types.

For the generic `<variant>` we would need something like:

     (DEFSTRUCT (<variant> (:CONSTRUCTOR NIL)))

And to take `defstruct` options into account we should also allow:

     (DEFSTRUCT (<variant> (:CONSTRUCTOR NIL) ... <opts> ...))

So let's use the following function:



```lisp
(defun build-type-struct (variant opts)
  `(defstruct (,variant (:constructor nil) ,@opts)))

(example (build-type-struct 'btree nil)
	 => '(DEFSTRUCT (BTREE (:CONSTRUCTOR NIL))))

(example (build-type-struct 'btree '((:type vector)))
         => '(DEFSTRUCT (BTREE (:CONSTRUCTOR NIL) (:TYPE VECTOR))))

```


Before continuing, let's define two nice utilities
 that originate from Paul Graham's OnLisp.



```lisp
(defun stringify (&rest args)  ;; originaly mkstr
  "Converts to a string and append all `ARGS`."
  (with-output-to-string (s)
    (dolist (a args) (princ a s))))

(example (stringify 'one- 2 "-three-" (+ 2 2))
         => "ONE-2-three-4")

(defun symbolize (&rest args) ;; originally symb
  "Converts to a string, append and create a symbol
from the result."
  (values (intern (apply #'stringify args))))

(example (symbolize 'one- 2 "-three-" (+ 2 2))
         => '|ONE-2-three-4|)

```



For each variant case `<caseI>` we would need something of the form:

    (DEFSTRUCT (<variant>-<caseI> (:include <variant>) ... <opts> ...)
	   <case_I_var_1> ... <case_I_var_M_I>)

This is generated by the following function:



```lisp
(defun build-case-struct (variant case-lbl opts case-vals)
  `(defstruct (,(symbolize variant "-" case-lbl) (:include ,variant) ,@opts)
	      ,@case-vals))

```


Let's try with our binary tree variant:



```lisp
(example (build-case-struct 'btree 'leaf '() '())
	 => '(DEFSTRUCT (BTREE-LEAF (:INCLUDE BTREE))))

(example (build-case-struct 'btree 'node '((:type list)) '(val left right))
	 => '(DEFSTRUCT (BTREE-NODE (:INCLUDE BTREE) (:TYPE LIST)) 
	      VAL LEFT RIGHT))

(example (build-case-struct 'btree 'node '((:type list)) '((val 0 (:type int)) left right))
	 => '(DEFSTRUCT (BTREE-NODE (:INCLUDE BTREE) (:TYPE LIST)) 
	      (VAL 0 (:TYPE INT)) LEFT RIGHT))

```


The next function will be used to generate all the case structures.

We first define an abbreviation for the mouthful `multiple-value-bind`.



```lisp
(defmacro lets (binders expr &body body)
  "An abbreviation for MULTIPLE-VALUE-BIND."
    `(multiple-value-bind ,binders ,expr ,@body)) 

(example (lets (a b c) (values 1 2 3)
           (+ a b c)) => 6)

```


And we are 



```lisp
(defun build-structs (variant opts cases)
  (cons (build-type-struct variant opts)
        (mapcar (lambda (case_)
                  (lets (case-lbl case-opts) (if (consp (car case_))
                                                 ;; label with options
                                                 (values (caar case_) (cdar case_))
                                                 ;; simple labels
                                                 (values (car case_) nil))
                    ;; build the cases
                    (build-case-struct variant case-lbl case-opts (cdr case_)))) cases)))

(example (build-structs 'btree nil
			'((leaf)
			  (node val left right)))
	 => '((DEFSTRUCT (BTREE (:CONSTRUCTOR NIL)))
	      (DEFSTRUCT (BTREE-LEAF (:INCLUDE BTREE)))
	      (DEFSTRUCT (BTREE-NODE (:INCLUDE BTREE)) VAL LEFT RIGHT)))

(example (build-structs 'btree '((:type vector))
                        '((leaf)
			  (node (val 0 (:type int)) left right)))
	 => '((DEFSTRUCT (BTREE (:CONSTRUCTOR NIL) (:TYPE VECTOR)))
              (DEFSTRUCT (BTREE-LEAF (:INCLUDE BTREE)))
              (DEFSTRUCT (BTREE-NODE (:INCLUDE BTREE)) (VAL 0 (:TYPE INT)) LEFT RIGHT)))


```


## The match macro

The difficult part of the exercise is to generate the `match-<variant>` macro ... 
from a `defvariant` expression. The general syntax of a match is as follows:

    (match-<variant> <expr>
      (<case_1> (<params_1>) <expr_1> ...)
      ...
      (<case_K> (<params_K>) <expr_K> ...)
      (t <expr_default> ...))

Note that we will require at least one case for a match to be well-formed.
Also the case expressions are implicitely `progn`'ed.

The dispatch algorithm for match is quite simple.

1. fetch the <case_id> corresponding to the value of the expression <expr>
2. dispatch to <expr_I> with the <params_I> bound according to <expr>

There are some hidden difficulties here, and there is also some work to do before
having a robust macro. So let's do this step-by-step.

Consider the following example:

    (match-btree (make-btree-leaf)
      (leaf () "leaf !")
      (node (v l r)  (format t "node: val=~A left=~A right=~A" v l r)))

This should obviously return `"leaf !"`.

The case fetched is thus `leaf` and no argument is bound while dispatching.

A second example is as follows:

    (match-btree (make-btree-node 12 (make-btree-leaf) (make-btree-leaf))
     (leaf () "leaf !")
     (node (v l r)  (format t "node: val=~A left=~A right=~A" v l r)))

This should now returns `"node: val=12 left=#S(BTREE-LEAF) right=#S(BTREE-LEAF)"`

Here the case is `node` and three arguments are bound for the tree components of the binary node.

Finally, something like:

    (match-btree 12
      (leaf () "leaf !")
      (node (v l r)  (format t "node: val=~A left=~A right=~A" v l r)))

should generate an error, as in various other misuses of the macro.
We introduce a condition type for match errors and another one
 for the warnings. 



```lisp
(define-condition match-error  (error)
  ((message :initarg :message
            :reader match-error-message))
  (:report (lambda (condition stream)
             (format stream "[Match error] ~A"
                     (match-error-message condition)))))

(define-condition match-warning  (warning)
  ((message :initarg :message
            :reader match-warning-message))
  (:report (lambda (condition stream)
             (format stream "[Match warning] ~A"
                     (match-warning-message condition)))))

```


### Match functions

A general case in a match expression is of the form:

    (<case_I>  <params_I> <expr_I> ...)

where `<params_I>` is either a list of parameters, or an
arbitrary symbol.

For the default case we have :
     (t <expr_default> ...)

From this we want to create a callable function of the 
form:

    (lambda <params_I> <expr_I> ...)

for `<case_I>` and `<params_I>` is a list, or:

    (lambda (&rest args)
        (declare (ignore args))
        <expr_I> ...)

if `<params_I>` is a symbol.

The default case will be of the form

    (lambda () <expr_default> ...)


We will add a special meaning for the variable `_` (underscore),
 that automatically ignore a match argument (as in ocaml).




```lisp
(defun build-lambda-parameters (params body)
  (let ((nparams (mapcar (lambda (param)
			   (if (equal (symbol-name param) "_")
			       (gensym "_")
			       param)) params)))
    (labels ((ignore-params (params nparams)
	       (if (null params)
		   (list)
		   (if (equal (symbol-name (car params)) "_")
		       (cons (car nparams) (ignore-params (cdr params) (cdr nparams)))
		       (ignore-params (cdr params) (cdr nparams))))))
      (let ((iparams (ignore-params params nparams)))
	`(lambda ,nparams
	   ,@(if iparams
		 `((declare (ignore ,@iparams)))
		 nil)
	   ,@body)))))

(example (build-lambda-parameters '(v l r) '(e1 e2 e3))
	 => '(LAMBDA (V L R) E1 E2 E3))


(example (build-lambda-parameters '(v l _) '(e1 e2 e3))
	 => '(LAMBDA (V L |_<gensymed>|) 
	      (DECLARE (IGNORE |_<gensymed>|))
	      E1 E2 E3)
	 :warn-only t)


(example (build-lambda-parameters '(_ l _) '(e1 e2 e3))
	 => '(LAMBDA (V L |_<gensymed>|) 
	      (DECLARE (IGNORE |_<gensymed>| |_<gensymed>|))
	      E1 E2 E3)
	 :warn-only t)

```


The `lambda` forms in general are created by the following function.




```lisp
(defun build-match-function (case-spec)
  (if (eql (car case-spec) t)
      ;; default case
      `(lambda () ,@(cdr case-spec))
      ;; normal case
      (if (consp (cadr case-spec))
	  ;; parameter list
	  (build-lambda-parameters (cadr case-spec) (cddr case-spec))
	  ;; no parameter list
	  (let ((args-var (gensym "args-")))
	    `(lambda (&rest ,args-var)
	       (declare (ignore ,args-var))
	       ,@(cddr case-spec))))))

(example (build-match-function '(leaf _ (princ "this is a ") (princ "leaf !")))
	 => '(LAMBDA (&REST |args-<gensymed>|)
	      (declare (IGNORE |args-<gensymed>|))
	      (PRINC "this is a ")
	      (PRINC "leaf !"))
	 :warn-only t)

```


Note that because of the `gensym`'ed variables the examples cannot serve 
as assertions, but the warning message shows that example is indeed "correct".



```lisp
(example (build-match-function '(node (v l r) (princ v) (princ l) (princ r)))
	 => '(LAMBDA (V L R)
	      (PRINC V)
	      (PRINC L) 
	      (PRINC R)))

(example (build-match-function '(node (v _ r) (princ v) (princ r)))
	 => '(LAMBDA (V |_<gensymed>| R)
	      (DECLARE (IGNORE |_<gensymed>|))
	      (PRINC V)
	      (PRINC R))
	 :warn-only t)

(example (build-match-function '(node _ (princ "this is a ") (princ "node !")))
	 => '(LAMBDA (&REST |args-<gensymed>|)
	      (DECLARE (IGNORE |args-<gensymed>|))
	      (PRINC "this is a ")
	      (PRINC "node !"))
	 :warn-only t)

(example (build-match-function '(t (princ "default ") (princ "case !")))
         => '(LAMBDA () (PRINC "default ") (PRINC "case !")))

```


### Match calls

Once we have our match function, we must perform a call with
the correct binding of:
 - the slot values for the matched case
 - to the correspond parameters in the selected match function.

For a case of the form:

    (<case-I> <params-I> <expr_I> ...)

and a match function called `match-fun` then the call will be 
of the following form:

    (<match-function> 
      (<variant>-<case-I>-<var-1> <val>)
       ...
      (<variant>-<case-I>-<var-M> <val))

and for the default case of the form

    (t <match-function>)

we will have an argument-less call to `match-fun`.

For example with:

    (match-btree (make-btree-leaf)
      (leaf () "leaf !")
      (node (v l r)  (format t "node: val=~A left=~A right=~A" v l r)))

we will have a call of the form:

    ((lambda () "leaf !"))

And with:

    (match-btree (make-btree-node 12 (make-btree-leaf) (make-btree-leaf))
     (leaf () "leaf !")
     (node (v l r)  (format t "node: val=~A left=~A right=~A" v l r)))

The call will be of the form:

    (let ((v (make-btree-node 12 (make-btree-leaf) (make-btree-leaf))))
    (match-fun 
      (btree-node-val v)
      (btree-node-left v)
      (btree-node-right v)))

The support function we rely on simply create the correct argument list.



```lisp
(defun build-match-args (variant case case-slots val)
  (flet ((build-params (params)
           (mapcar (lambda (param)
                     `(,(symbolize variant "-" case "-" param) ,val))
                   params)))
    (if (eql case t)
	nil
	`(,@(build-params case-slots)))))


(example (build-match-args 'btree 'leaf (list) 'v)
	 => NIL)

(example (build-match-args 'btree 'node '(val left right) 'v)
	 => '((BTREE-NODE-VAL v)
	      (BTREE-NODE-LEFT v)
	      (BTREE-NODE-RIGHT v)))

(example (build-match-args 'btree t nil 'val)
	 => NIL)

```


As a companion to `build-match-args`, we define an auxiliary function to fetch the
 slots of a given variant case.



```lisp
(defun build-case-slots (case-id variant-cases)
  (labels ((fetch-case-slots (variant-cases)
             (if (null variant-cases)
                 (error 'match-error :message (format nil "No such variant case: ~A" case-id))
                 (if (or (and (consp (caar variant-cases))
                              (eql (caaar variant-cases) case-id)) ;; case with opts
                         (eql (caar variant-cases) case-id))  ;; case without opts
                     (mapcar (lambda (slot)
                               (if (consp slot)
                                   (car slot)  ;; slot with opts
                                   slot))  ;; slot witout opts
                             (cdar variant-cases))
                     ;; otherwise search next
                     (fetch-case-slots (cdr variant-cases))))))
    ;; body
    (if (eql case-id t)
        nil
        (fetch-case-slots variant-cases))))

(example (build-case-slots 'leaf '((leaf) (node val left right)))
	 => NIL)

(example (build-case-slots 'node '((leaf) (node val left right)))
	 => '(val left right))

(example (build-case-slots 'node '((leaf) ((node (:type list)) val left right)))
	 => '(val left right))

(example (build-case-slots 'node '((leaf) ((node (:type list)) (val 0 (:type int)) left right)))
	 => '(val left right))

(example (build-case-slots 't '((leaf) (node val left right)))
         => nil)

(example (handler-case (build-case-slots 'hello '((leaf) ((node (:type list)) val left right)))
           (match-error (err) (match-error-message err)))
         => "No such variant case: HELLO")

```


### Dispatch algorithm

The dispatch algorithm can now be built by traversing
simultenaously the case specifications and the corresponding
 match functions.


Now we can write the core of the dispatch algorithm.
This simply consists in elaborating a list of `cond` clauses, each
 clause being of the form:

    (<condition> (<match-function> <match-arguments>))

The `<match-function>` is obtained by `build-match-function` and the
`<match-arguments>` are prepared thanks to `build-match-args` and
 `build-case-slots` already defined.

The only missing piece in the puzzle is the `<condition>` expression, that
is either `t` in the default case, or of the form:

    (<variant>-<case->-p <val>)

where `<val>` is the value on which we dispatch.

For example, for the binary trees we would have:

    (btree-leaf-p <val>)

for the leaves, or:

    (btree-node-p <val>)

for internal nodes.



```lisp
(defun build-condition (variant case-id val)
  (if (eql case-id t)
      't
      `(,(symbolize variant "-" case-id "-P")
         ,val)))

(example (build-condition 'btree 'leaf 'v)
         => '(BTREE-LEAF-P v))

(example (build-condition 'btree 'node 'v)
         => '(BTREE-NODE-P v))

(example (build-condition 'btree 't 'v)
         => 'T)

```


We are finally ready to build the case dispatch function.
The definition below is a little bit verbose. And it is based on a
recursive building of cases (cf. subfunction `build-cases`).
This is because we take advantage of going through all the cases to
perform some compile-time error checking.  We also do some compile-time
 exhaustiveness checks.

But there is not deep difficulty in the code below.



```lisp
(defun build-dispatch (variant variant-cases match-cases val)
  (labels 
      ((build-cases (match-cases known-cases)
	 (if (null match-cases)
	     (if (null known-cases)
		 (error 'match-error :message "No case in match")
		 ;; do some exhaustiveness checks
		 (let ((missing-cases (remove-duplicates (set-difference (mapcar #'car variant-cases) known-cases))))
		   (if (not (member 't known-cases))
		       ;; default case is not present
		       (progn 
			 (if (consp missing-cases)
			     ;; not all cases taken into account
			     (warn 'match-warning :message (stringify "Non-exhaustive match, missing cases: " missing-cases)))
			 `((t (error 'match-error :message ,(stringify "Cannot match argument: not a " variant)))))
		       ;; default case is present
		       (progn
			 (if (null missing-cases)
			     ;; all cases taken into account
			     (warn 'match-warning :message (stringify "Default case redundant: match is exhaustive")))
			 (list)))))
	     ;; recursive case
	     (let ((match-case (car match-cases)))
	       ;; some checks
	       (cond ((and (eql (car match-case) t)
			   (consp (cdr match-cases)))
		      (error 'match-error :message "Default case must be last in match"))
		     ((member (car match-case) known-cases)
		      (error 'match-error :message (stringify "Duplicate case in match: " (car match-case))))
		     (t
		      (let ((condition
			     (build-condition variant (car match-case) val)) 
			    (match-fun 
			     (build-match-function match-case))
			    (match-args 
			     (build-match-args variant 
					       (car match-case)
					       (build-case-slots (car match-case) 
								 variant-cases) 
					       val)))
			(cons `(,condition (,match-fun ,@match-args))
			      (build-cases (cdr match-cases) (cons (car match-case) known-cases))))))))))
    ;; body
    `(cond ,@(build-cases match-cases '()))))


```


Let's begin by a general example.




```lisp
(example (build-dispatch 'btree
                         '((leaf) (node val left right))
                         '((leaf () "leaf !")
                           (node (v l r)  "node !"))
                         'val)
	 =>
	 '(COND 
           ((BTREE-LEAF-P VAL) ((LAMBDA (&rest |args-<gensymed>|)
                                  (declare (ignore |args-<gensymed>|))
                                  "leaf !")))
           ((BTREE-NODE-P VAL) ((LAMBDA (V L R)
                                  "node !")
                                (BTREE-NODE-VAL VAL)
                                (BTREE-NODE-LEFT VAL)
                                (BTREE-NODE-RIGHT VAL)))
           (T (ERROR 'MATCH-ERROR :MESSAGE
	       "Cannot match argument: not a BTREE")))
         :warn-only t)

```


#### Compile-time error checking ####

We give below a few example illustrating the different checks we
perform at compile-time.

First, let check for the special case when there is no case in the match.



```lisp
(example (handler-case (build-dispatch 'test '((dummy)) '() 'val)
           (match-error (err) (match-error-message err)))
         => "No case in match")


```


Then, we check that the default `t` case is last in



```lisp
(example (handler-case (build-dispatch 'test '((dummy)) '((dummy () "dummy")
                                                          (t "oops !")
                                                          (dummy () "dumb dummy")) 'val)
           (match-error (err) (match-error-message err)))
         => "Default case must be last in match")


```


Now let's see with an unkwnown case.



```lisp
(example (handler-case (build-dispatch 'test '((dummy)) '((dummy () "dummy")
                                                          (pfumg "oops !")
                                                          (dummy () "dumb dummy")) 'val)
           (match-error (err) (match-error-message err)))
         => "No such variant case: PFUMG")

```


And finally the check for duplicated cases.



```lisp
(example (handler-case (build-dispatch 'test '((dummy)) '((dummy () "dummy")
                                                          (dummy () "dumb dummy")
                                                          (t "oops !")) 'val)
           (match-error (err) (match-error-message err)))
         => "Duplicate case in match: DUMMY")

```


#### Exhaustiveness checks

Let's check if non-exhaustive check is signaled correctly.



```lisp
(example (handler-case (build-dispatch 'test '((leaf) (bnode) (tnode)) 
				       '((leaf () "leaf !")
					 (tnode () "tnode !")) 'val)
           (match-warning (wrn) (match-warning-message wrn)))
         => "Non-exhaustive match, missing cases: (BNODE)")


```


The second check is if the match is exhaustive and a default
case is explicitely provided.



```lisp
(example (handler-case (build-dispatch 'test '((leaf) (bnode) (tnode)) 
				       '((leaf () "dummy =")
					 (tnode () "tnode !")
					 (bnode () "bnode !")
					 (t () "default !")) 'val)
           (match-warning (wrn) (match-warning-message wrn)))
         => "Default case redundant: match is exhaustive")

```


### The match macro

The macro-generation part of the `defvariant` macro is where most tricks
 happen. It is not a difficult macro but the generation is perfomed
 in two stages, thus we rely on _nested backquotes_ which is the ABC
 of macro wizardry.

The best way to explain such macro-generated macro is to first show the
glory details.



```lisp
(defun build-match-macro (variant variant-cases)
  `(defmacro ,(symbolize "MATCH-" variant) (expr &body match-cases)
     ,(format nil "Match values of variant type: ~A." variant)
     (let ((expr-var (gensym "-val")))
       `(let ((,expr-var ,expr))
	  ,(build-dispatch `,',variant `,',variant-cases match-cases expr-var)))))

```


The `defmacro`  must be protected of course because we do not want to
expanse now since with do not know the `expr` nor the `match-cases` while
 generating the match macro.  

Consider the example of the match-macro for our binary trees:



```lisp
(example (build-match-macro 'btree 
			    '((leaf) (node val left right)))
	 => '(DEFMACRO MATCH-BTREE (EXPR &BODY MATCH-CASES)
              "Match values of variant type: BTREE."
	      (LET ((EXPR-VAR (GENSYM "-val")))
		`(LET ((,EXPR-VAR ,EXPR))
		   ,(BUILD-DISPATCH 'BTREE '((LEAF) (NODE VAL LEFT RIGHT)) 
				    MATCH-CASES EXPR-VAR)))))

```


The tricky bit is here: when the argument `variant` is `BTREE`,  then the ```,',variant' gets expanded into `'BTREE`. This is not easy to explain but let's try.

First, notice that we are initially in the scope of two backquotes: the one of `defmacro` and the one of `LET`. The comma before `build-dispatch` "removes" the `let` backquote, however there is still one level of backquoting, which explains why the function `build-dispatch` is not called and remains quoted.  Now, we add one level of backquoting so that we can unquote the next quote... 
 Our goal, indeed, is to produce something of the form `'<value>`   (in the example `'BTREE`).
 Let's jump to the final comma. Since it occurs under a single quasiquote (the `defmacro` one), the `,variant` gets expanded to `BTREE`  (`<value>` in the general case). This value is prepended not by a "real" `quote` but by a quasiquoted one, hence producing `(quote BTREE)`.  Without the qusiquote as protection, the quote would be evaluated and we would obtain `BTREE` (or `<value>`) since for any `<value>`, `(quote <value>)` *is* `<value>`.

Well... I don't know if I can find a better explanation myself, so if you are lost I urge you to (re)read Paul Graham's **On Lisp**  (especially Chapter 16).

Wow ! this looks like it might work ...

## Wrapping up

The final touch ouf our system is simply the combination of definining the
structures and generating the match macro.



```lisp
(defmacro defvariant (variant &body variant-cases)
  (lets (variant-lbl variant-opts)
      (if (consp variant)
          (values (car variant) (cdr variant))
          (values variant '()))
    `(progn ,@(build-structs variant-lbl variant-opts variant-cases)
            ,(build-match-macro variant-lbl variant-cases))))

```


And now let's try our `defvariant` form.




```lisp
(example (defvariant btree
           (leaf)
           (node val left right))
         => 'MATCH-BTREE)

(example (match-btree 12
	   (leaf _ "leaf !")
	   (node _ "node !")
	   (t "default !"))
	 => "default !")

(example (handler-case (match-btree 12
                         (leaf _ "leaf !")
                         (node _ "node !"))
           (match-error (err) (match-error-message err)))
         => "Cannot match argument")

(example (match-btree (make-btree-leaf)
	   (leaf _ "leaf !")
	   (node _ "node !")
	   (t "default !"))
	 => "leaf !")


(example (match-btree (make-btree-node :val 42 :left (make-btree-leaf) :right (make-btree-leaf))
	   (leaf _ "leaf !")
	   (node (v l r) (format nil "node: val=~A left=~A right=~A" v l r))
	   (t "default !"))
	 => "node: val=42 left=#S(BTREE-LEAF) right=#S(BTREE-LEAF)")


(example (match-btree (make-btree-node :val 42 :left (make-btree-leaf) :right (make-btree-leaf))
	   (leaf _ "leaf !")
	   (node (v _ _) v)
	   (t "default !"))
	 => 42)


```


That's all folks !





