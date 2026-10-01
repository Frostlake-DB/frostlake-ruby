# frozen_string_literal: true

# A Ruby driver for Frostlake, speaking the engine's HTTP protocol against a
# running DatabaseHttpServer.
#
#   require "frostlake"
#   conn = Frostlake.connect("frostlake://localhost:18082/MY_DB?schema=PUBLIC")
#   result = conn.execute("SELECT id, name FROM people WHERE id = ?", [1])
#   result.rows # => [{ "ID" => 1, "NAME" => "Ada" }]
#
# Parameters are inlined client-side (the protocol has no server-side binding),
# with the same rules as Frostlake's other drivers. Rows are hashes keyed by
# column name; BOOLEAN cells arrive as booleans, DATE as Date, TIMESTAMP* as
# Time, BINARY as a binary-encoded String. Fixed-point NUMBER keeps its exact
# digits as BigDecimal (or Integer at scale 0) while FLOAT/DOUBLE/REAL stay
# Float. A bound Time is sent as TIMESTAMP_TZ, since a Ruby Time always carries
# a UTC offset.

require "date"
require "json"
require "monitor"
require "net/http"
require "time"
require "uri"

begin
  # Ships with Ruby: a default gem through 3.3, a bundled one from 3.4. Without
  # it, fixed-point cells fall back to Float rather than failing to load.
  require "bigdecimal"
rescue LoadError
  nil
end

module Frostlake
  VERSION = "0.2.0"

  # Every failure the driver raises is a Frostlake::Error, so one rescue still
  # catches the lot; the subclasses only say which kind it was.
  class Error < StandardError; end

  # The server could not be reached, or the connection failed mid-statement.
  class ConnectionError < Error; end

  # The engine no longer holds the connection's session: it expired, was
  # released, or the server restarted. Raised instead of re-running the
  # statement when the lost session held what a fresh one cannot reproduce —
  # an open transaction, or context set up with USE, SET, ALTER SESSION or a
  # temporary object. The statement did not run, and the connection stays
  # usable: its next statement starts a fresh session on the DSN's database
  # and schema.
  class SessionLostError < ConnectionError; end

  # The engine rejected a statement. The message is the engine's own.
  class QueryError < Error; end

  # The driver was asked for something impossible: a malformed DSN, a closed
  # connection, a bind value with no SQL equivalent.
  class UsageError < Error; end

  DEFAULT_PORT = 18_082

  # Everything the DSN query string may carry. Anything else is a typo, and a
  # typo in schema or read_timeout changes behaviour without saying so.
  DSN_PARAMETERS = ["ca_file", "open_timeout", "read_timeout", "schema",
                    "session_idle_limit", "verify_ssl"].freeze

  # Long enough for a slow query, short enough that an unreachable host fails
  # while someone is still watching.
  DEFAULT_OPEN_TIMEOUT = 10
  DEFAULT_READ_TIMEOUT = 300

  # The engine reaps a session after 30 minutes idle. An engine that predates
  # newSession says nothing when it does, so past that we have to assume ours
  # is gone.
  DEFAULT_SESSION_IDLE_LIMIT = 1800

  # How long closing may spend releasing the session, in seconds, to connect
  # and again to be answered; a connection timeout that is shorter wins.
  CLOSE_BUDGET = 5

  # The engine's binary floating-point types. Every other numeric it reports is
  # fixed-point and keeps its digits.
  APPROXIMATE_TYPES = ["FLOAT", "FLOAT4", "FLOAT8", "DOUBLE", "DOUBLE PRECISION", "REAL"].freeze

  # A character of an unquoted identifier or keyword. $ is one, which is why
  # A$$B is a name.
  WORD_CHAR = /[[:alnum:]_$]/.freeze

  # The words that may sit between CREATE, DROP or ALTER and the kind of
  # object the statement names.
  OBJECT_MODIFIERS = ["OR", "REPLACE", "TRANSIENT", "TEMPORARY", "TEMP", "VOLATILE", "LOCAL", "GLOBAL",
                      "SECURE", "IF", "NOT", "EXISTS", "PUBLIC", "PRIVATE", "ICEBERG", "DYNAMIC",
                      "HYBRID", "EVENT", "RECURSIVE", "MATERIALIZED", "EXTERNAL"].freeze

  # The modifiers that make an object temporary: it lives only as long as the
  # session that created it.
  TEMPORARY = ["TEMPORARY", "TEMP", "VOLATILE"].freeze
  private_constant :WORD_CHAR, :OBJECT_MODIFIERS, :TEMPORARY

  # Connects, verifies the server is reachable via GET /api/health, and applies
  # the database and schema from the DSN. Timeouts are in seconds; verify_ssl
  # and ca_file apply to https DSNs. All four may also be given in the DSN
  # query string, where an explicit argument outranks them.
  def self.connect(dsn, open_timeout: nil, read_timeout: nil, verify_ssl: nil, ca_file: nil,
                   session_idle_limit: nil)
    conn = Connection.new(dsn, open_timeout: open_timeout, read_timeout: read_timeout,
                          verify_ssl: verify_ssl, ca_file: ca_file,
                          session_idle_limit: session_idle_limit)
    begin
      conn.ping
      conn.use_dsn_defaults
    rescue StandardError
      # Nothing usable came of it, so do not leave a session behind.
      conn.close
      raise
    end
    conn
  end

  class Result
    include Enumerable

    # values is every cell, positionally aligned with columns — the shape the
    # wire actually delivered.
    attr_reader :columns, :row_count, :values

    def initialize(columns, row_count, values = [])
      @columns = columns
      @row_count = row_count
      @values = values
      # A Result outlives the statement that made it and can be handed between
      # threads, so the memoisation below must not be two half-built copies.
      @rows_lock = Mutex.new
    end

    # Each row keyed by column name, built on first use and kept. A hash cannot
    # represent two columns called the same thing — a self-join reports ID
    # twice and the later one wins — so values is the lossless view. Building
    # these lazily keeps a caller that only reads values from paying for them.
    def rows
      @rows_lock.synchronize { @rows ||= build_rows }
    end

    def each(&block)
      rows.each(&block)
    end

    private

    def build_rows
      @values.map do |cells|
        row = {}
        @columns.each_with_index do |column, i|
          row[column[:name]] = cells[i]
        end
        row
      end
    end
  end

  class Connection
    # What round_trip answers when the engine refused the session id as one it
    # no longer holds. Nothing ran.
    SESSION_GONE = :session_gone
    private_constant :SESSION_GONE

    def initialize(dsn, open_timeout: nil, read_timeout: nil, verify_ssl: nil, ca_file: nil,
                   session_idle_limit: nil)
      uri = begin
        URI.parse(dsn)
      rescue URI::InvalidURIError
        raise UsageError, "invalid DSN: #{dsn}"
      end
      scheme = (uri.scheme || "").downcase
      unless %w[frostlake http https].include?(scheme)
        raise UsageError, "DSN must start with frostlake://, http:// or https://"
      end
      raise UsageError, "DSN is missing host[:port]" if uri.host.nil? || uri.host.empty?
      # The server authenticates nobody, so credentials in a DSN would be
      # quietly dropped — and quietly dropping a password is worse than saying so.
      unless uri.userinfo.nil?
        raise UsageError, "the server takes no credentials; remove user:password from the DSN"
      end

      query = uri.query.nil? ? {} : URI.decode_www_form(uri.query).to_h
      unknown = query.keys - DSN_PARAMETERS
      unless unknown.empty?
        raise UsageError, "unknown DSN parameter: #{unknown.sort.join(', ')} " \
                          "(expected #{DSN_PARAMETERS.join(', ')})"
      end
      @host = uri.host
      # URI supplies 80 and 443 for http and https; only the custom scheme needs
      # the engine's own default.
      @port = uri.port || DEFAULT_PORT
      unless (1..65_535).cover?(@port)
        raise UsageError, "DSN port must be between 1 and 65535, got #{@port}"
      end
      # Net::HTTP opens a fresh connection per request, which is deliberate:
      # against DatabaseHttpServer a reused connection costs ~48 ms a statement
      # (a delayed-ACK stall that TCP_NODELAY does not shift) versus ~0.8 ms for
      # a new one. Do not "optimise" this into a kept-alive session.
      @http = Net::HTTP.new(@host, @port)
      if scheme == "https"
        configure_tls(verify_ssl, ca_file, query)
      elsif !verify_ssl.nil? || !ca_file.nil? || query.key?("verify_ssl") || query.key?("ca_file")
        # However they were spelled — keyword or DSN — they would do nothing here.
        raise UsageError, "verify_ssl and ca_file apply to https DSNs only"
      end
      @http.open_timeout = self.class.timeout_for("open_timeout", open_timeout,
                                                  query["open_timeout"], DEFAULT_OPEN_TIMEOUT)
      @http.read_timeout = self.class.timeout_for("read_timeout", read_timeout,
                                                  query["read_timeout"], DEFAULT_READ_TIMEOUT)
      # One socket and one session id per connection: statements serialize so a
      # Connection can be shared between threads without interleaving them. A
      # Monitor rather than a Mutex because execute_all holds the lock across
      # the round trips it makes, each of which takes it again.
      @lock = Monitor.new
      @session_idle_limit = self.class.idle_limit_for(session_idle_limit,
                                                      query["session_idle_limit"])
      @last_used_at = nil
      # Whether the caller has selected anything themselves; if they have, the
      # DSN's defaults are no longer the whole truth about this session.
      @session_touched = false
      @session_id = nil
      # Whether the engine reports newSession, which arrived together with
      # requireSession and DELETE /api/sessions: nil until the first answer
      # that names a session, which settles it either way.
      @tracks_sessions = nil
      # What the session holds that a fresh one would not: context a statement
      # set up (USE, SET, ALTER SESSION, a temporary object, CREATE or DROP of a
      # database or schema), and an open transaction.
      @dirty = false
      @in_transaction = false
      @autocommit = true
      @closed = false
      @pending_use = []
      # A trailing slash is fine; a second segment means the caller meant
      # something the DSN cannot express, and "db/extra" is not an identifier.
      database = (uri.path || "").delete_prefix("/").delete_suffix("/")
      if database.include?("/")
        raise UsageError, "the DSN path names one database, got #{uri.path.inspect}"
      end
      schema = query["schema"]
      @pending_use << "USE DATABASE #{self.class.use_ident(database)}" unless database.empty?
      @pending_use << "USE SCHEMA #{self.class.use_ident(schema)}" if schema
      # Kept so they can be put back if the session is replaced under us.
      @session_defaults = @pending_use.dup.freeze
    end

    def closed?
      @closed
    end

    # Applies the database and schema named in the DSN. connect calls this, so
    # a name that does not exist is reported there rather than surfacing later
    # on whatever query happens to run first.
    def use_dsn_defaults
      check_open
      @lock.synchronize { apply_pending_use }
      nil
    end

    def ping
      check_open
      @lock.synchronize do
        response = begin
          @http.get("/api/health")
        rescue IOError, SocketError, SystemCallError, Timeout::Error => e
          raise ConnectionError, "cannot reach #{@host}:#{@port}: #{e.message}"
        end
        raise ConnectionError, "server unhealthy: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      end
      nil
    end

    # Executes one statement; returns a Result whose rows are hashes keyed by
    # column name and whose row_count is the affected-row count for DML. A
    # multi-statement string answers with its first result set — use
    # execute_all for the rest.
    def execute(sql, binds = [], multi_statement_count: nil)
      execute_all(sql, binds, multi_statement_count: multi_statement_count).first
    end

    # Executes a statement string and returns every result set it produced, in
    # order. A single statement gives a one-element array.
    #
    # multi_statement_count says how many statements this call carries, 0 for
    # any number; the engine refuses a call whose count differs, as the account
    # does. It rides on this one request and outranks the session's
    # MULTI_STATEMENT_COUNT for it without changing any session state, so there
    # is nothing to restore and a connection shared between threads is
    # unaffected. Left out, nothing is sent and the session's value decides.
    def execute_all(sql, binds = [], multi_statement_count: nil)
      check_open
      unless multi_statement_count.nil? ||
             (multi_statement_count.is_a?(Integer) && !multi_statement_count.negative?)
        raise UsageError, "multi_statement_count must be a non-negative Integer, " \
                          "got #{multi_statement_count.inspect}"
      end
      rendered = binds.empty? ? sql : self.class.substitute(sql, binds)
      # The pending USE statements and the statement itself have to reach the
      # session as one unit: another thread must not slip a query in between,
      # and two threads must not both try to shift the same pending entry.
      @lock.synchronize do
        results = shape_results(perform(rendered, multi_statement_count))
        @session_touched = true if self.class.selects_session_state?(sql)
        results
      end
    end

    # Opens a transaction: BEGIN, sent with autocommit off. The connection
    # leaves autocommit only once the engine has opened the transaction, so a
    # BEGIN that fails — refused, unreadable, never answered, lost with its
    # session, or never sent because a USE queued ahead of it was refused —
    # leaves every later statement committing as it runs.
    def begin_transaction
      @lock.synchronize do
        perform("BEGIN", nil, false)
        @autocommit = false
      end
      nil
    end

    def commit
      @lock.synchronize do
        execute("COMMIT")
        @autocommit = true
      end
      nil
    end

    def rollback
      @lock.synchronize do
        execute("ROLLBACK")
        @autocommit = true
      end
      nil
    end

    # Runs the block inside BEGIN ... COMMIT, rolling back on any exception.
    def transaction
      begin_transaction
      result = yield self
      commit
      result
    rescue StandardError
      begin
        rollback
      rescue StandardError
        # A failed rollback must not replace the exception that caused it.
        nil
      end
      raise
    end

    # Closes the connection and releases its session on the engine with one
    # DELETE /api/sessions/{id}, which also rolls back a transaction left open.
    # The release is best effort, bounded by CLOSE_BUDGET, and never raises;
    # an engine that predates it is sent nothing, and keeps the session until
    # its own idle expiry. Closing again sends nothing.
    def close
      @closed = true
      @lock.synchronize do
        release_session
        @http.finish if @http.started?
      rescue IOError
        # Already gone; closing is still closing.
        nil
      end
      nil
    end

    private

    def check_open
      raise UsageError, "connection is closed" if @closed
    end

    # One statement on the session, under the lock: the pending USE statements
    # first, with the connection's own autocommit, then the statement with
    # auto_commit, and the session's state tracked from it. Answers the
    # engine's answer.
    def perform(sql, multi_statement_count, auto_commit = @autocommit)
      # Again under the lock: a close that got in first has released the
      # session, and a statement now would start one nobody releases.
      check_open
      restore_session_defaults
      # Each pending USE is one statement of its own, whatever this call declares.
      apply_pending_use
      out = run(sql, multi_statement_count, auto_commit)
      track_session(sql)
      out
    end

    # Runs one statement on the session, or — when the engine no longer holds
    # it — once more on a fresh one, if nothing the lost session held is lost
    # with it. Sent again, it carries the autocommit it was first sent with.
    def run(sql, multi_statement_count, auto_commit = @autocommit)
      out = round_trip(sql, multi_statement_count, auto_commit)
      return out unless out == SESSION_GONE

      session_lost
      apply_pending_use
      out = round_trip(sql, multi_statement_count, auto_commit)
      raise SessionLostError, "the engine refused a session it had just started" if out == SESSION_GONE

      out
    end

    # Sends the pending USE statements, one request each. A session lost or
    # replaced part-way takes the USEs already sent with it, so the whole of
    # the DSN's scope goes onto the fresh one: once, since an engine that loses
    # the session again within the same few requests is keeping none. And a
    # scope that fails part-way stays pending in full, so no statement runs in
    # a scope nobody chose.
    def apply_pending_use
      restarted = false
      until @pending_use.empty?
        queue = @pending_use.dup
        answer = begin
          round_trip(queue.first)
        rescue Error
          @pending_use.replace(@session_defaults.dup)
          raise
        end
        if answer == SESSION_GONE
          raise SessionLostError, "the engine refused a session it had just started" if restarted

          restarted = true
          session_lost
        elsif @pending_use == queue || restarted
          @pending_use.replace(queue.drop(1))
        else
          # absorb found the session replaced and queued the scope again.
          restarted = true
        end
      end
    end

    # The engine no longer holds the session: it expired, was released, or the
    # server restarted, and nothing ran. With a transaction or a moved context
    # gone with it, re-running would put the statement somewhere its author
    # did not intend, so that raises; either way the id is dropped and the
    # DSN's scope queued, so the next statement starts a fresh session there.
    def session_lost
      had_transaction = @in_transaction
      had_context = @dirty
      forget_session
      if had_transaction
        raise SessionLostError,
              "the engine no longer holds this connection's session (it expired, was released, " \
              "or the server restarted), so its open transaction is gone; the statement did not run"
      end
      return unless had_context

      raise SessionLostError,
            "the engine no longer holds this connection's session (it expired, was released, " \
            "or the server restarted), and the context set up on it (USE, SET, ALTER SESSION or " \
            "a temporary object) went with it, so the statement was not re-run; the next " \
            "statement starts a fresh session on the connection's scope"
    end

    # Starts over: no session, nothing held on one, and the DSN's scope queued
    # for the next statement. A transaction lost with the session takes the
    # driver's autocommit-off with it.
    def forget_session
      @autocommit = true if @in_transaction
      @session_id = nil
      @dirty = false
      @in_transaction = false
      @pending_use.replace(@session_defaults.dup)
    end

    # Keeps the connection's picture of its session in step with a statement
    # that succeeded: whether it left context behind that a fresh session would
    # not have, and whether a transaction is open.
    def track_session(sql)
      self.class.statements(sql).each do |statement|
        @dirty = true if self.class.touches_session?(statement)
        case self.class.transaction_effect(statement)
        when :begins then @in_transaction = true
        when :ends then @in_transaction = false
        end
      end
    end

    # Learns from an answer which session it ran in, and whether the engine
    # tracks sessions: an answer naming one carries newSession, or comes from
    # an engine older than the field, requireSession and DELETE /api/sessions.
    def absorb(out, sent_id)
      id = out["sessionId"]
      return if id.nil?

      if out.key?("newSession")
        @tracks_sessions = true
        # The engine ran the statement in a fresh session in place of ours, so
        # whatever the old one held is gone, and the DSN's scope goes back on
        # before the next statement.
        forget_session if out["newSession"] == true && !sent_id.nil?
      elsif @tracks_sessions.nil?
        @tracks_sessions = false
      end
      @session_id = id
    end

    # One DELETE /api/sessions/{id}, bounded and never raising. Releasing the
    # session also rolls back a transaction it left open.
    def release_session
      id = @session_id
      @session_id = nil
      @in_transaction = false
      return if id.nil? || !@tracks_sessions

      @http.open_timeout = [@http.open_timeout, CLOSE_BUDGET].min
      @http.read_timeout = [@http.read_timeout, CLOSE_BUDGET].min
      @http.write_timeout = [@http.write_timeout, CLOSE_BUDGET].min
      # Net::HTTP re-sends an idempotent request once after a timeout, which
      # would double the budget.
      @http.max_retries = 0
      path = "/api/sessions/#{URI.encode_www_form_component(id).gsub('+', '%20')}"
      @http.request(Net::HTTP::Delete.new(path))
      nil
    rescue StandardError
      # Best effort: the engine's idle expiry releases whatever this did not.
      nil
    end

    # An engine that predates newSession reaps a session once it has been idle
    # long enough and then quietly builds a fresh one for the id we keep
    # sending, losing the database and schema we selected. Nothing in its reply
    # gives it away — the id we sent is echoed back either way, and
    # /api/sessions reports only a count — so past the limit the only safe
    # reading is that the session is new, and the DSN's defaults go back on.
    # Not once the caller has selected something themselves: putting our
    # defaults over their choice is its own surprise. A later engine refuses a
    # session it no longer holds, and run puts the scope back itself.
    def restore_session_defaults
      return unless @tracks_sessions == false
      return if @session_defaults.empty? || @session_touched
      return if @session_idle_limit.zero? || @last_used_at.nil?
      return if self.class.monotonic_now - @last_used_at < @session_idle_limit

      @pending_use.concat(@session_defaults)
    end

    def configure_tls(verify_ssl, ca_file, query)
      begin
        require "openssl"
      rescue LoadError
        raise UsageError, "an https DSN needs openssl, which this Ruby was built without"
      end

      @http.use_ssl = true
      verify = self.class.boolean_for("verify_ssl", verify_ssl, query["verify_ssl"], true)
      @http.verify_mode = verify ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
      authority = ca_file.nil? ? query["ca_file"] : ca_file
      @http.ca_file = authority unless authority.nil?
    end

    # One POST /api/execute: the parsed answer, or SESSION_GONE when the
    # engine refused the session id as one it no longer holds. auto_commit is
    # the request's autocommit: the connection's own unless a statement asks
    # for another, as BEGIN does.
    def round_trip(sql, multi_statement_count = nil, auto_commit = @autocommit)
      @lock.synchronize do
        sent_id = @session_id
        # Resume this session or refuse, rather than have the engine start a
        # fresh one under the same id where the statement would run without
        # the context set up earlier. Only to an engine known to take the
        # field: an older one might refuse a field it does not know.
        required = !sent_id.nil? && @tracks_sessions == true
        payload = { "sql" => sql, "autoCommit" => auto_commit }
        payload["sessionId"] = sent_id if sent_id
        payload["requireSession"] = true if required
        # Absent unless this call asked for a count: a request without the field
        # is the one the server has always been sent, and the session decides.
        payload["multiStatementCount"] = multi_statement_count unless multi_statement_count.nil?
        request = Net::HTTP::Post.new("/api/execute", "content-type" => "application/json")
        request.body = JSON.generate(payload)
        response = begin
          @http.request(request)
        rescue IOError, SocketError, SystemCallError, Timeout::Error => e
          raise ConnectionError, "request failed: #{e.message}"
        end
        # Failed statements answer with a non-2xx status AND the error payload in the body.
        out = begin
          self.class.parse_json(response.body)
        rescue JSON::ParserError
          raise ConnectionError, "HTTP #{response.code} with unreadable body"
        end
        # A 404 that names no session is the refusal requireSession asked for.
        if required && response.code.to_s == "404" && !out["success"] && out["sessionId"].nil?
          return SESSION_GONE
        end

        absorb(out, sent_id)
        raise QueryError, out["errorMessage"] || "statement failed" unless out["success"]

        @last_used_at = self.class.monotonic_now
        out
      end
    end

    def shape_results(out)
      sets = out["resultSets"]
      return [Result.new([], 0, [])] if sets.nil? || sets.empty?

      results = []
      sets.each do |result_set|
        results << shape_result(result_set)
      end
      results
    end

    def shape_result(result_set)
      columns = (result_set["columns"] || []).map do |c|
        # length is a text column's width in characters and a binary column's in
        # bytes. Every other type sends none, and so does a server that predates
        # the field: it stays nil rather than becoming a width of 0.
        { name: c["name"], data_type: c["dataType"], scale: c["scale"], length: c["length"] }
      end
      values = (result_set["rows"] || []).map do |raw|
        cells = []
        columns.each_with_index do |column, i|
          cells << self.class.convert(raw[i], column[:data_type], column[:scale])
        end
        cells
      end
      if values.length == 1 && self.class.dml_status?(columns)
        return Result.new([], self.class.dml_row_count(columns, values[0]), [])
      end

      Result.new(columns, values.length, values)
    end

    class << self
      # Always quoted. Leaving "unambiguous" names bare let through ones that
      # cannot legally appear unquoted — 1ABC starts with a digit, SELECT is
      # reserved — and quoting costs nothing: "NAME" and NAME name the same
      # object, so only genuinely lower-case names are affected and those had to
      # be quoted anyway.
      def quote_ident(name)
        text = name.to_s
        raise UsageError, "identifier cannot be empty" if text.empty?

        "\"#{text.gsub('"', '""')}\""
      end

      # A DSN's database or schema, rendered for USE. A plain name means what it
      # means unquoted in SQL — the upper-case object it folds to — so it is
      # folded before it is quoted; anything else is quoted exactly as given.
      # Quoted as given, a lower-case name would ask for a lower-case object,
      # which USE refuses: it resolves names exactly, as live does.
      def use_ident(name)
        text = name.to_s
        text = text.upcase if text.match?(/\A[A-Za-z_][A-Za-z0-9_$]*\z/)
        quote_ident(text)
      end

      # Keeps every JSON number exact: the engine serializes fixed-point
      # numerics from BigDecimal, and Float would round the digits away before
      # convert ever sees them.
      def parse_json(text)
        return JSON.parse(text) unless defined?(BigDecimal)

        JSON.parse(text, decimal_class: BigDecimal)
      end

      def convert(value, data_type, scale = 0)
        return nil if value.nil?

        case (data_type || "").upcase
        when "DATE"
          value.is_a?(String) ? Date.parse(value) : value
        when "TIMESTAMP", "TIMESTAMP_NTZ", "DATETIME"
          value.is_a?(String) ? wall_clock(value) : value
        when "TIMESTAMP_LTZ", "TIMESTAMP_TZ"
          value.is_a?(String) ? Time.parse(value) : value
        when "BINARY", "VARBINARY"
          value.is_a?(String) ? decode_hex(value) : value
        else
          convert_number(value, (data_type || "").upcase, scale)
        end
      end

      # A TIMESTAMP_NTZ is a wall clock with no zone, and its text carries none.
      # Read in the process's local zone, a wall clock that zone skips would be
      # moved — 01:30 on the night London springs forward would come back as
      # 02:30 — and what a caller read would depend on the machine. UTC skips
      # nothing, so the text is read there: every field comes back as written,
      # on every host, and the instant is the one the engine's epoch arithmetic
      # gives the value. Text with an offset of its own keeps it, since the
      # parser takes the first zone it meets.
      def wall_clock(text)
        Time.parse("#{text} UTC")
      end

      # The engine renders binary as hex. Anything else is not ours to
      # reinterpret: pack("H*") turns "ZZ" into a byte and pads odd-length input
      # rather than admitting it was handed something else.
      def decode_hex(text)
        return text unless text.match?(/\A(?:[0-9a-fA-F]{2})*\z/)

        [text].pack("H*")
      end

      # Fixed-point columns keep the wire's exact digits; FLOAT/DOUBLE/REAL are
      # genuine binary floats and stay that way. Anything non-numeric — strings,
      # booleans, semi-structured JSON text — passes straight through.
      def convert_number(value, data_type, scale)
        return value unless value.is_a?(Numeric)
        return value.to_f if APPROXIMATE_TYPES.include?(data_type)
        return value if value.is_a?(Integer)
        return value unless defined?(BigDecimal) && value.is_a?(BigDecimal)
        # Scale 0 is an integer column; hand back an Integer, but never truncate
        # a value that unexpectedly carries a fraction.
        return value.to_i if scale.to_i.zero? && value.frac.zero?

        value
      end

      # Whether a result set is a DML status row rather than data. The protocol
      # carries no statement type, so this goes by shape: DML answers with a
      # single row whose every column is a "number of ..." counter. INSERT and
      # DELETE report one, UPDATE adds "number of multi-joined rows updated",
      # and MERGE reports both an inserted and an updated count.
      def dml_status?(columns)
        return false if columns.empty?

        columns.each do |column|
          return false unless column[:name].to_s.downcase.start_with?("number of ")
        end
        true
      end

      # Total rows affected. "number of multi-joined rows updated" is a
      # diagnostic sub-count of rows already counted as updated, so only the
      # "number of rows ..." counters are summed.
      def dml_row_count(columns, cells)
        total = 0
        columns.each_with_index do |column, i|
          next unless column[:name].to_s.downcase.start_with?("number of rows ")

          value = cells[i]
          total += value.to_i unless value.nil?
        end
        total
      end

      # A clock that cannot jump backwards over an idle connection.
      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Zero switches the idle check off; anything else is seconds.
      def idle_limit_for(argument, from_dsn)
        given = argument.nil? ? from_dsn : argument
        return DEFAULT_SESSION_IDLE_LIMIT if given.nil?

        seconds = Float(given)
        raise UsageError, "session_idle_limit cannot be negative, got #{given}" if seconds.negative?

        seconds
      rescue ArgumentError, TypeError
        raise UsageError, "session_idle_limit must be a number of seconds, got #{given.inspect}"
      end

      # A USE picks the database, schema, warehouse or role for the session.
      # Once the caller has done that themselves, the DSN no longer describes
      # where they are, so the driver stops putting its defaults back.
      def selects_session_state?(sql)
        /(\A|[;\n])\s*USE\s/i.match?(sql)
      end

      # -- session tracking --------------------------------------------------

      # The request split on its top-level semicolons, blank pieces dropped. A
      # semicolon inside a literal, a quoted identifier, a $$ body or a comment
      # does not split: the same constructs substitute steps over. A scripting
      # block is split along with everything else, which only makes the checks
      # below more willing to flag a request, the safe direction to be wrong in.
      def statements(sql)
        pieces = []
        start = 0
        i = 0
        while i < sql.length
          past = skip_non_code(sql, i)
          if past
            i = past
          elsif sql[i] == ";"
            pieces << sql[start...i]
            start = i + 1
            i += 1
          else
            i += 1
          end
        end
        pieces << sql[start..]
        pieces.reject { |piece| piece.strip.empty? }
      end

      # Up to limit leading words of a statement, upper-cased, skipping
      # whitespace and comments and stopping at the first thing that is not a
      # word.
      def leading_words(statement, limit)
        words = []
        i = 0
        while words.length < limit && i < statement.length
          ch = statement[i]
          nxt = statement[i + 1]
          if ch.match?(/\s/)
            i += 1
          elsif (ch == "-" && nxt == "-") || (ch == "/" && nxt == "/")
            i = skip_line(statement, i)
          elsif ch == "/" && nxt == "*"
            stop = statement.index("*/", i + 2)
            i = stop.nil? ? statement.length : stop + 2
          elsif ch.match?(WORD_CHAR)
            start = i
            i += 1 while i < statement.length && statement[i].match?(WORD_CHAR)
            words << statement[start...i].upcase
          else
            break
          end
        end
        words
      end

      # Whether a statement leaves behind state a fresh session would not have:
      # a moved scope (USE, or CREATE or DROP of a DATABASE or SCHEMA), a
      # session variable or setting (SET, UNSET, ALTER SESSION), or a temporary
      # object. CREATE TABLE and its kind leave the session as it was.
      def touches_session?(statement)
        verb, *rest = leading_words(statement, 16)
        case verb
        when "USE", "SET", "UNSET"
          true
        when "ALTER"
          rest.drop_while { |word| OBJECT_MODIFIERS.include?(word) }.first == "SESSION"
        when "CREATE", "DROP"
          modifiers = rest.take_while { |word| OBJECT_MODIFIERS.include?(word) }
          return true if %w[DATABASE SCHEMA].include?(rest[modifiers.length])

          verb == "CREATE" && modifiers.any? { |word| TEMPORARY.include?(word) }
        else
          false
        end
      end

      # :begins, :ends or nil — what a statement does to the session's
      # transaction. BEGIN on its own (or with TRANSACTION, WORK or NAME) opens
      # one; BEGIN followed by a statement opens a scripting block instead.
      def transaction_effect(statement)
        words = leading_words(statement, 2)
        return :ends if %w[COMMIT ROLLBACK].include?(words.first)
        return :begins if words == ["START", "TRANSACTION"]
        return nil unless words.first == "BEGIN"

        words.length == 1 || %w[TRANSACTION WORK NAME].include?(words[1]) ? :begins : nil
      end

      # An explicit argument wins over the DSN, which wins over the default.
      def boolean_for(name, argument, from_dsn, fallback)
        given = argument.nil? ? from_dsn : argument
        return fallback if given.nil?
        return given if given == true || given == false

        case given.to_s.downcase
        when "true", "1", "yes" then true
        when "false", "0", "no" then false
        else
          raise UsageError, "#{name} must be true or false, got #{given.inspect}"
        end
      end

      # An explicit argument wins over the DSN, which wins over the default.
      def timeout_for(name, argument, from_dsn, fallback)
        given = argument.nil? ? from_dsn : argument
        return fallback if given.nil?

        seconds = Float(given)
        raise UsageError, "#{name} must be positive, got #{given}" unless seconds.positive?

        seconds
      rescue ArgumentError, TypeError
        raise UsageError, "#{name} must be a number of seconds, got #{given.inspect}"
      end

      # -- client-side parameter binding ------------------------------------

      def substitute(sql, binds)
        out = +""
        nxt = 0
        i = 0
        while i < sql.length
          ch = sql[i]
          if ch == "'"
            j = skip_string(sql, i)
            out << sql[i...j]
            i = j
          elsif ch == '"'
            j = skip_quoted(sql, i)
            out << sql[i...j]
            i = j
          elsif ch == "-" && sql[i + 1] == "-"
            j = skip_line(sql, i)
            out << sql[i...j]
            i = j
          elsif ch == "/" && sql[i + 1] == "*"
            stop = sql.index("*/", i + 2)
            j = stop.nil? ? sql.length : stop + 2
            out << sql[i...j]
            i = j
          elsif ch == "/" && sql[i + 1] == "/"
            j = skip_line(sql, i)
            out << sql[i...j]
            i = j
          elsif ch == "$" && sql[i + 1] == "$"
            j = skip_dollar_quoted(sql, i)
            out << sql[i...j]
            i = j
          elsif ch == "?"
            raise UsageError, "not enough bind values for placeholders" if nxt >= binds.length

            out << format_literal(binds[nxt])
            nxt += 1
            i += 1
          else
            out << ch
            i += 1
          end
        end
        out
      end

      def format_literal(value)
        case value
        when nil then "NULL"
        when true then "TRUE"
        when false then "FALSE"
        when Integer then value.to_s
        when Float
          raise UsageError, "non-finite number #{value}" unless value.finite?

          value.to_s
        # A Ruby Time always carries a UTC offset, so it maps to TIMESTAMP_TZ;
        # casting to NTZ here silently discarded that offset.
        when Time then "'#{value.strftime('%Y-%m-%dT%H:%M:%S.%6N%:z')}'::TIMESTAMP_TZ"
        when DateTime then format_literal(value.to_time)
        when Date then "'#{value.strftime('%Y-%m-%d')}'::DATE"
        when String
          # A binary-encoded string is the deliberate marker for BINARY data.
          if value.encoding == Encoding::ASCII_8BIT
            "X'#{value.unpack1('H*').upcase}'"
          else
            encode_string(value)
          end
        when Symbol then encode_string(value.to_s)
        when Array then "[#{value.map { |element| format_literal(element) }.join(', ')}]"
        else
          if defined?(BigDecimal) && value.is_a?(BigDecimal)
            value.to_s("F")
          else
            raise UsageError, "unsupported bind type #{value.class}"
          end
        end
      end

      private

      # Index just past the literal, quoted identifier, $$ body or comment
      # starting at i, or nil when i is code; the rules substitute follows.
      def skip_non_code(sql, i)
        ch = sql[i]
        nxt = sql[i + 1]
        if ch == "'"
          skip_string(sql, i)
        elsif ch == '"'
          skip_quoted(sql, i)
        elsif (ch == "-" && nxt == "-") || (ch == "/" && nxt == "/")
          skip_line(sql, i)
        elsif ch == "/" && nxt == "*"
          stop = sql.index("*/", i + 2)
          stop.nil? ? sql.length : stop + 2
        elsif ch == "$" && nxt == "$"
          skip_dollar_quoted(sql, i)
        end
      end

      def skip_string(sql, i)
        j = i + 1
        while j < sql.length
          if sql[j] == "\\"
            j += 2 # backslash always escapes
          elsif sql[j] == "'"
            return j + 1 unless sql[j + 1] == "'"

            j += 2
          else
            j += 1
          end
        end
        j
      end

      def skip_quoted(sql, i)
        j = i + 1
        while j < sql.length
          if sql[j] == '"'
            return j + 1 unless sql[j + 1] == '"'

            j += 2
          else
            j += 1
          end
        end
        j
      end

      # Steps over a $$…$$ block. UDF and procedure bodies are written that
      # way, so a ? inside one is part of the body, not a placeholder.
      def skip_dollar_quoted(sql, i)
        stop = sql.index("$$", i + 2)
        stop.nil? ? sql.length : stop + 2
      end

      def skip_line(sql, i)
        j = sql.index("\n", i)
        j.nil? ? sql.length : j + 1
      end

      def encode_string(text)
        "'#{text.gsub('\\', '\\\\\\\\').gsub("'", "''")}'"
      end
    end
  end
end
