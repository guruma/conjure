(module conjure.client.clojure.nrepl.server
  {require {a conjure.aniseed.core
            uuid conjure.uuid
            text conjure.text
            net conjure.net
            view conjure.aniseed.view
            bencode conjure.bencode
            bencode-stream conjure.bencode-stream
            state conjure.client.clojure.nrepl.state
            config conjure.client.clojure.nrepl.config
            ui conjure.client.clojure.nrepl.ui}})

(defn with-conn-or-warn [f]
  (let [conn (a.get state :conn)]
    (if conn
      (f conn)
      (ui.display ["; No connection"]))))

(defn- dbg [desc data]
  (when config.debug?
    (ui.display
      (a.concat
        [(.. "; debug " desc)]
        (text.split-lines (view.serialise data)))))
  data)

(defn send [msg cb]
  (let [conn (a.get state :conn)]
    (when conn
      (let [msg-id (uuid.v4)]
        (a.assoc msg :id msg-id)
        (dbg "->" msg)
        (a.assoc-in conn [:msgs msg-id]
                    {:msg msg
                     :cb (or cb (fn []))
                     :sent-at (os.time)})
        (conn.sock:write (bencode.encode msg))
        nil))))

(defn- display-conn-status [status]
  (with-conn-or-warn
    (fn [conn]
      (ui.display [(.. "; " conn.raw-host ":" conn.port " (" status ")")]
                  {:break? true}))))

(defn disconnect []
  (with-conn-or-warn
    (fn [conn]
      (when (not (conn.sock:is_closing))
        (conn.sock:read_stop)
        (conn.sock:shutdown)
        (conn.sock:close))
      (display-conn-status :disconnected)
      (a.assoc state :conn nil))))

(defn- status= [msg state]
  (and msg msg.status (a.some #(= state $1) msg.status)))

(defn with-all-msgs-fn [cb]
  (let [acc []]
    (fn [msg]
      (table.insert acc msg)
      (when (status= msg :done)
        (cb acc)))))

(defn close-session [session cb]
  (send {:op :close :session session} cb))

(defn assume-session [session]
  (a.assoc-in state [:conn :session] session)
  (ui.display [(.. "; Assumed session: " session)]
              {:break? true}))

(defn clone-session [session]
  (send
    {:op :clone
     :session session}
    (with-all-msgs-fn
      (fn [msgs]
        (assume-session (a.get (a.last msgs) :new-session))))))

(defn with-sessions [cb]
  (with-conn-or-warn
    (fn [_]
      (send
        {:op :ls-sessions}
        (fn [msg]
          (let [sessions (->> (a.get msg :sessions)
                              (a.filter
                                (fn [session]
                                  (not= msg.session session))))]
            (table.sort sessions)
            (cb sessions)))))))

(defn assume-or-create-session []
  (with-sessions
    (fn [sessions]
      (if (a.empty? sessions)
        (clone-session)
        (assume-session (a.first sessions))))))

(defn- handle-read-fn []
  (vim.schedule_wrap
    (fn [err chunk]
      (let [conn (a.get state :conn)]
        (if
          err (display-conn-status err)
          (not chunk) (disconnect)
          (->> (bencode-stream.decode-all state.bs chunk)
               (a.run!
                 (fn [msg]
                   (dbg "<-" msg)
                   (let [cb (a.get-in conn [:msgs msg.id :cb] #(ui.display-result nil $1))
                         (ok? err) (pcall cb msg)]
                     (when (not ok?)
                       (ui.display [(.. "; conjure.client.clojure.nrepl error: " err)]))
                     (when (status= msg :unknown-session)
                       (ui.display ["; Unknown session, correcting"])
                       (assume-or-create-session))
                     (when (status= msg :done)
                       (a.assoc-in conn [:msgs msg.id] nil)))))))))))

(defn- handle-connect-fn []
  (vim.schedule_wrap
    (fn [err]
      (let [conn (a.get state :conn)]
        (if err
          (do
            (display-conn-status err)
            (disconnect))

          (do
            (conn.sock:read_start (handle-read-fn))
            (display-conn-status :connected)
            (assume-or-create-session)))))))

(defn connect [{: host : port}]
  (let [resolved-host (net.resolve host)
        conn {:sock (vim.loop.new_tcp)
              :host resolved-host
              :raw-host host
              :port port
              :msgs {}
              :session nil}]

    (when (a.get state :conn)
      (disconnect))

    (a.assoc state :conn conn)
    (conn.sock:connect resolved-host port (handle-connect-fn))))

(defn eval [opts cb]
  (with-conn-or-warn
    (fn [_]
      (send
        {:op :eval
         :code opts.code
         :file opts.file-path
         :line (a.get-in opts [:range :start 1])
         :column (-?> (a.get-in opts [:range :start 2]) (a.inc))
         :session (a.get-in state [:conn :session])}
        cb))))