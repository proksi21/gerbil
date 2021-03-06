;;; -*- Gerbil -*-
;;; (C) vyzo at hackzen.org
;;; thread primitives and gambit runtime symbols
package: gerbil/gambit

(export (except-out #t construct-actor-thread *thread-locals* *thread-locals-mutex*))
(extern namespace: #f
  current-thread
  thread?
  make-thread
  make-root-thread
  thread-name
  thread-specific
  thread-specific-set!
  thread-base-priority
  thread-base-priority-set!
  thread-priority-boost
  thread-priority-boost-set!
  thread-quantum
  thread-quantum-set!
  thread-start!
  thread-yield!
  thread-sleep!
  thread-terminate!
  thread-join!
  thread-send
  thread-receive
  thread-mailbox-next
  thread-mailbox-rewind
  thread-mailbox-extract-and-rewind
  mutex?
  make-mutex
  mutex-name
  mutex-specific
  mutex-specific-set!
  mutex-state
  mutex-lock!
  mutex-unlock!
  condition-variable?
  make-condition-variable
  condition-variable-name
  condition-variable-specific
  condition-variable-specific-set!
  condition-variable-signal!
  condition-variable-broadcast!

  ;; miscellanea
  make-thread-group thread-group? thread-group-name
  thread-group-specific thread-group-specific-set!
  thread-group-parent thread-group-resume! thread-group-suspend!
  thread-group-terminate! thread-group->thread-group-list
  thread-group->thread-group-vector thread-group->thread-list
  thread-group->thread-vector
  thread-state thread-state-uninitialized? thread-state-initialized?
  thread-state-running? thread-state-running-processor
  thread-state-waiting? thread-state-waiting-for thread-state-waiting-timeout
  thread-state-normally-terminated?
  thread-state-normally-terminated-result
  thread-state-abnormally-terminated?
  thread-state-abnormally-terminated-reason
  top thread-interrupt! thread-suspend! thread-resume!
  thread-thread-group thread-init!

  ;; system processors
  processor? current-processor processor-id
  )

;;; spawn and friends
(def (spawn f . args)
  (spawn-actor f args #!void #f))

(def (spawn/name name f . args)
  (spawn-actor f args name #f))

(def (spawn/group name f . args)
  (let (tgroup (make-thread-group name))
    (spawn-actor f args name tgroup)))

(def (spawn-actor f args name tgroup)
  (def (thread-main thunk)
    ;; install an abortive handler to force stack unwinding
    ;; this ensures that unwind-protect finalizers are invoked if
    ;; the actor exits with an unhandled exception.
    ;; debugging: when the unhandled-actor-exception-hook is set, then
    ;; it is invoked with the continuation and exception before unwinding
    ;; the stack.
    ;; in particular, set the hook to dump-stack-trace! to dump the
    ;; continuation backtrace together with the exception to ##stderr-port
    (lambda ()
      (with-exception-handler
       (lambda (exn)
         (##continuation-capture
          (lambda (cont)
            (when unhandled-actor-exception-hook
              (with-catch void (cut unhandled-actor-exception-hook cont exn)))
            ;; unwind stack and continue with the primordial exception handler
            ;; see discussion in gambit#295 about ##continuation-last
            (##continuation-graft
             (##continuation-last cont)
             ##primordial-exception-handler
             exn))))
       thunk)))

  (if (procedure? f)
    (let ((thunk (if (null? args) f
                     (lambda () (apply f args))))
          (tgroup (or tgroup (current-thread-group))))
      (thread-start!
       (thread-init!
        (construct-actor-thread #f)
        (thread-main thunk) name tgroup)))
    (error "Bad argument; expected procedure" f)))

(extern
  actor-thread? construct-actor-thread
  actor-thread-locals actor-thread-locals-set!)
(begin-foreign
  (namespace ("gerbil/gambit/threads#"
              construct-actor-thread actor-thread?
              actor-thread-locals actor-thread-locals-set!))
  (define-type-of-thread actor-thread
    constructor: construct-actor-thread
    id: gerbil#actor-thread::t
    locals))

(def (spawn-thread thunk (name absent-obj) (tgroup absent-obj))
  (thread-start!
   (make-thread thunk name tgroup)))

;;; thread locals
(def (thread-local-ref key (default absent-obj))
  (let (tab (thread-local-table))
    (hash-ref tab key default)))

(def (thread-local-get key)
  (thread-local-ref key #f))

(def (thread-local-set! key value)
  (let (tab (thread-local-table))
    (hash-put! tab key value)))

(def (thread-local-clear! key)
  (let (tab (thread-local-table))
    (hash-remove! tab key)))

(def (thread-local-table)
  (let (thr (current-thread))
    (cond
     ((actor-thread? thr)
      (cond
       ((actor-thread-locals thr) => values)
       (else
        (let (tab (make-hash-table-eq))
          (actor-thread-locals-set! thr tab)
          tab))))
     ((eq? thr ##primordial-thread)
      *primordial-thread-locals*)
     (else
      (mutex-lock! *thread-locals-mutex*)
      (cond
       ((hash-get *thread-locals* thr)
        => (lambda (tab)
             (mutex-unlock! *thread-locals-mutex*)
             tab))
       (else
        (let (tab (make-hash-table-eq))
          (hash-put! *thread-locals* thr tab)
          (mutex-unlock! *thread-locals-mutex*)
          tab)))))))

(def *primordial-thread-locals*
  (make-hash-table-eq))

(def *thread-locals*
  (make-hash-table-eq weak-keys: #t))

(def *thread-locals-mutex*
  (make-mutex 'thread-locals))

;;; actor debug hooks
(def unhandled-actor-exception-hook #f)
(def (unhandled-actor-exception-hook-set! proc)
  (if (or (not proc) (procedure? proc))
    (set! unhandled-actor-exception-hook proc)
    (error "Bad argument; expected procedure or #f" proc)))

;; evaluate a thunk with an exception handler that dumps the stack trace
(def (with-exception-stack-trace thunk (error-port (current-error-port)))
  (with-exception-handler
   (let (E (current-exception-handler))
     (lambda (exn)
       (##continuation-capture
        (lambda (cont)
          (dump-stack-trace! cont exn error-port)
          (E exn)))))
   thunk))

;; hook to dump continuation backtraces to an error port
(extern dump-stack-trace!)
(begin-foreign
  (namespace ("gerbil/gambit/threads#" dump-stack-trace!))

  (define (dump-stack-trace! cont exn #!optional (error-port (current-error-port)))
    (let ((out (open-output-string)))
      (display "*** Unhandled exception in " out)
      (display (current-thread) out)
      (newline out)
      (display-exception exn out)
      (display "Continuation backtrace: " out)
      (newline out)

      (##display-continuation-backtrace
       cont
       out
       #f                               ; display-env?
       #f                               ; all-frames?
       ##backtrace-default-max-head
       ##backtrace-default-max-tail
       0)

      (##write-string (get-output-string out) error-port))))

;;; utitilities
(def (current-thread-group)
  (thread-thread-group (current-thread)))

(def (with-lock mx proc)
  (dynamic-wind
      (cut mutex-lock! mx)
      proc
      (cut mutex-unlock! mx)))
