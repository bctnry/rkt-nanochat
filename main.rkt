#lang racket/base
(require racket/cmdline)
(require racket/gui/base)
(require racket/class)
(require racket/string)
(require racket/tcp)


(define *regex-cmd* #rx"^/([^ ]+)(.*)")
(define *current-session* (void))
(define *current-output-adapter* (void))

(define (read-number-line in)
  (let* ((l (read-line in))
         (n (string->number (string-trim l))))
    (if (not n)
        (error (format "read-number-line: failed to parse line ~a\n" l))
        n)))

(struct client-session
  (is-open?
   in out mutex poll-thread poll-delay nick
   last-msg-id
   host port
   output-adapter) #:mutable #:transparent)

(define (session-send session msg)
  (let ((in (client-session-in session))
        (out (client-session-out session)))
    (call-with-semaphore
     (client-session-mutex session)
     (λ ()
       (display (format "SEND ~a\n" msg) out)
       (flush-output out)
       (let* ((last-msg-id (read-number-line in)))
         (values last-msg-id))))))

(define (session-skip session n)
  (let ((in (client-session-in session))
        (out (client-session-out session)))
    (call-with-semaphore
     (client-session-mutex session)
     (λ ()
       (display (format "SKIP ~a\n" n) out)
       (flush-output out)
       (let* ((n (read-number-line in))
              (msgs (for/list ([i (in-range n)]) (read-line in)))
              (last-msg-id (read-number-line in)))
         (values msgs last-msg-id))))))

(define (session-last session n)
  (let ((in (client-session-in session))
        (out (client-session-out session)))
    (call-with-semaphore
     (client-session-mutex session)
     (λ ()
       (display (format "LAST ~a\n" n) out)
       (flush-output out)
       (let* ((n (read-number-line in))
              (msgs (for/list ([i (in-range n)]) (read-line in)))
              (last-msg-id (read-number-line in)))
         (values msgs last-msg-id))))))

(define (session-poll session last-msg-id)
  (let ((in (client-session-in session))
        (out (client-session-out session)))
    (call-with-semaphore
     (client-session-mutex session)
     (λ ()
       (display (format "POLL ~a\n" last-msg-id) out)
       (flush-output out)
       (read-number-line in)))))

(define (session-quit session)
  (call-with-semaphore
   (client-session-mutex session)
   (λ ()
     (display "QUIT\n" (client-session-out session))
     (flush-output (client-session-out session))
     (set-client-session-is-open?! session #f)
     (thread-suspend (client-session-poll-thread session))
     (close-output-port (client-session-out session))
     (close-input-port (client-session-in session)))))

(define (session-hist session)
  (let ((in (client-session-in session))
        (out (client-session-out session)))
    (call-with-semaphore
     (client-session-mutex session)
     (λ ()
       (display "HIST\n" out)
       (flush-output out)
       (let* ((n (read-number-line in))
              (msgs (for/list ([i (in-range n)]) (read-line in)))
              (last-msg-id (read-number-line in)))
         (values n msgs last-msg-id))))))

(define (session-stat session)
  (let ((in (client-session-in session))
        (out (client-session-out session)))
    (call-with-semaphore
     (client-session-mutex session)
     (λ ()
       (display "STAT\n" out)
       (flush-output out)
       (let ((msgs (read-line in))
             (bcount (read-line in))
             (clients (read-line in)))
         (values msgs bcount clients))))))

(struct output-adapter
  (system-msg-func
   normal-msg-func)
  #:mutable #:transparent)

(define (session/change-nick session new-nick)
  (let ((old-nick (client-session-nick session)))
    (set-client-session-nick! session new-nick)
    (let ((adapter (client-session-output-adapter session)))
      ((output-adapter-system-msg-func adapter)
       (format "(changed nick from ~a to ~a)" old-nick new-nick)))))

(define (session/reuse session host port)
  (when (client-session-is-open? session)
    (session-quit session))
  (let-values ([(in out) (tcp-connect host port)])
    (set-client-session-in! session in)
    (set-client-session-out! session out)
    (set-client-session-host! session host)
    (set-client-session-port! session port)
    (let-values ([(msg last-msg-id) (session-last session 1)])
      (for ([i (in-list msg)])
        ((output-adapter-normal-msg-func
          (client-session-output-adapter session))
         i))
      (set-client-session-last-msg-id! session last-msg-id))
    (thread-resume (client-session-poll-thread session))
    (set-client-session-is-open?! session #t)))

(define (session/start host port output-adapter)
  (let ((s (client-session
            #f
            (void) (void)
            (make-semaphore 1)
            (void) 10
            "__user"
            0
            host port
            output-adapter)))
    (let-values ([(in out) (tcp-connect host port)])
      (set-client-session-in! s in)
      (set-client-session-out! s out)
      (set-client-session-is-open?! s #t)
      (let-values ([(msg last-msg-id) (session-last s 1)])
        (set-client-session-last-msg-id! s last-msg-id)
        (let ((t (thread
                  (λ ()
                    (let loop ()
                      (when (client-session-is-open? s)
                        (let* ((n (session-poll s (client-session-last-msg-id s))))
                          (let-values ([(msgs last-msg-id) (session-last s n)])
                            (for ([i (in-list msgs)])
                              ((output-adapter-normal-msg-func
                                (client-session-output-adapter s)) i))
                            (set-client-session-last-msg-id! s last-msg-id))))
                      (sleep (client-session-poll-delay s))
                      (loop))))))
          (set-client-session-poll-thread! s t))))
    s))

(define frm-main
  (new frame%
       [label "nanochat"]
       [alignment '(left center)]
       [width 500]
       [height 300]))
(define edit-main
  (new editor-canvas%
       [parent frm-main]))
(define text-main
  (new text%
       [auto-wrap #t]
       ))

(define default-font-style-delta
  (let ((sd (make-object style-delta%)))
    (send sd set-face "Unifont")
    sd))
(send text-main change-style default-font-style-delta)
(define normal-msg-style-delta
  (let ((sd (make-object style-delta%)))
    (send sd set-delta-foreground "Black")
    (send sd set-style-off 'italic)
    (send sd set-weight-off 'bold)
    sd))
(send text-main change-style normal-msg-style-delta)
(define system-msg-style-delta
  (let ((sd (make-object style-delta%)))
    (send sd set-delta-foreground "Dim Gray")
    (send sd set-style-on 'italic)
    (send sd set-weight-off 'bold)
    sd))
(define nickname-style-delta
  (let ((sd (make-object style-delta%)))
    (send sd set-delta-foreground "Black")
    (send sd set-style-off 'italic)
    (send sd set-weight-on 'bold)
    sd))

(set! *current-output-adapter*
      (output-adapter
       (λ (sys-msg)
         (send text-main change-style system-msg-style-delta)
         (for ([i (in-list (string-split sys-msg "\n"))])
           (display-log-msg (format "SYS>> ~a\n" i))))
       (λ (normal-msg)
         (send text-main change-style normal-msg-style-delta)
         (display-log-msg (format "~a\n" normal-msg)))))

(send edit-main set-editor text-main)

(define lbl-nick
  (new message%
       [parent frm-main]
       [label "Nickname: __user"]))

(define (send-msg msg)
  (session-send *current-session*
                (format "~a: ~a" (client-session-nick *current-session*) msg)))

(define (send-me-msg msg)
  (session-send *current-session*
                (format "*~a ~a*" (client-session-nick *current-session*) msg)))

(define (display-log-msg msg)
  (let* ((endpos (send text-main get-end-position)))
    (send text-main insert msg endpos)))

(define (change-nick new-nick)
  (session/change-nick *current-session* new-nick)
  (send lbl-nick set-label (format "Nickname: ~a" new-nick)))

(define (hist)
  (let-values ([(n msg last-msg-id) (session-hist *current-session*)])
    (for ([i (in-list msg)])
      ((output-adapter-normal-msg-func
        (client-session-output-adapter *current-session*)) i))
    (set-client-session-last-msg-id! *current-session* last-msg-id)))

(define (stat)
  (let-values ([(a b c) (session-stat *current-session*)])
    (let ((of (output-adapter-system-msg-func
               (client-session-output-adapter *current-session*))))
      (of a)
      (of b)
      (of c))))

(define (set-tick tick-second-str)
  (set-client-session-poll-delay! *current-session* (string->number tick-second-str)))

(define (quit-current-session)
  ((output-adapter-system-msg-func *current-output-adapter*)
   (format "disconnecting from ~a ~a\n"
           (client-session-host *current-session*)
           (client-session-port *current-session*)))
  (session-quit *current-session*))

      
(define (connect cmdbodyraw)
  (let ((adapter *current-output-adapter*)
        (ll (string-split cmdbodyraw)))
    (let ((host (car ll))
          (port (if (>= (length ll) 2) (string->number (cadr ll)) 44322)))
      (if (void? *current-session*)
          (set! *current-session* (session/start host port adapter))
          (session/reuse *current-session* host port))
      ((output-adapter-system-msg-func *current-output-adapter*)
       (format "connected to ~a ~a" host port)))))

(define (last-n-msg cmdbodyraw)
  (let ((l (string->number cmdbodyraw)))
    ((output-adapter-system-msg-func *current-output-adapter*)
     (format "(last ~a msg)" l))
    (let-values ([(msgs last-msg-id) (session-last *current-session* l)])
      (for ([i (in-list msgs)])
        ((output-adapter-normal-msg-func
          (client-session-output-adapter *current-session*)) i))
      (set-client-session-last-msg-id! *current-session* last-msg-id))))

(define (help)
  ((output-adapter-system-msg-func *current-output-adapter*)
   (string-join
    (list
     "/nick [new-nick] - change nickname"
     "/me [msg] - send a message which would display as you doing something."
     "/hist - retrieve history of the connected server"
     "/stat - retrieve stats of the connected server"
     "/tick [second] - change poll delay"
     "/quit - disconnect from current server"
     "/last [n] - fetch last [n] messages"
     "/connect [host] [port?] - connect to server"
     "/help - show this help message"
     "/font [font-name] - switch the font")
    "\n")))

(define (change-font cmdbodyraw)
  (let ((sd (make-object style-delta%)))
    (send sd set-face cmdbodyraw)
    (send text-main change-style sd 0 (send text-main get-end-position)))
  ((output-adapter-system-msg-func *current-output-adapter*)
   (format "changed font to ~a" cmdbodyraw)))

(define tf-cmd
  (new text-field%
       [label ""]
       [parent frm-main]
       [callback (λ (tf e)
                   (when (equal? (send e get-event-type) 'text-field-enter)
                     (let* ((cmd (send tf get-value))
                            (matchres (regexp-match *regex-cmd* cmd)))
                       (if (not matchres)
                           (send-msg cmd)
                           (let ((cmdhead (cadr matchres))
                                 (cmdbodyraw (string-trim (caddr matchres))))
                             (cond
                               ((string=? cmdhead "nick") (change-nick cmdbodyraw))
                               ((string=? cmdhead "me") (send-me-msg cmdbodyraw))
                               ((string=? cmdhead "hist") (hist))
                               ((string=? cmdhead "stat") (stat))
                               ((string=? cmdhead "tick") (set-tick cmdbodyraw))
                               ((string=? cmdhead "quit") (quit-current-session))
                               ((string=? cmdhead "last") (last-n-msg cmdbodyraw))
                               ((string=? cmdhead "connect") (connect cmdbodyraw))
                               ((string=? cmdhead "help") (help))
                               ((string=? cmdhead "font") (change-font cmdbodyraw))
                               ))))
                     (send tf set-value "")
                     ))]))

(send frm-main show #t)
((output-adapter-system-msg-func *current-output-adapter*)
 "(write your message in the text field below and press ENTER to send)")

