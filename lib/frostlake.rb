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
  VERSION = "0.1.0"

  # Every failure the driver raises is a Frostlake::Error, so one rescue still
  # catches the lot; the subclasses only say which kind it was.
  class Error < StandardError; end

  # The server could not be reached, or the connection failed mid-statement.
  class ConnectionError < Error; end

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

  # The engine reaps a session after 30 minutes idle. Past that we have to
  # assume ours is gone, because nothing in a response says so.
  DEFAULT_SESSION_IDLE_LIMIT = 1800

  # The engine's binary floating-point types. Every other numeric it reports is
  # fixed-point and keeps its digits.
  APPROXIMATE_TYPES = ["FLOAT", "FLOAT4", "FLOAT8", "DOUBLE", "DOUBLE PRECISION", "REAL"].freeze

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
      @pending_use << "USE DATABASE #{self.class.quote_ident(database)}" unless database.empty?
      @pending_use << "USE SCHEMA #{self.class.quote_ident(schema)}" if schema
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
      @lock.synchronize do
        round_trip(@pending_use.shift) until @pending_use.empty?
      end
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
    def execute(sql, binds = [])
      execute_all(sql, binds).first
    end

    # Executes a statement string and returns every result set it produced, in
    # order. A single statement gives a one-element array.
    def execute_all(sql, binds = [])
      check_open
      rendered = binds.empty? ? sql : self.class.substitute(sql, binds)
      # The pending USE statements and the statement itself have to reach the
      # session as one unit: another thread must not slip a query in between,
      # and two threads must not both try to shift the same pending entry.
      @lock.synchronize do
        restore_session_defaults
        round_trip(@pending_use.shift) until @pending_use.empty?
        results = shape_results(round_trip(rendered))
        @session_touched = true if self.class.selects_session_state?(sql)
        results
      end
    end

    def begin_transaction
      @lock.synchronize do
        @autocommit = false
        execute("BEGIN")
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

    def close
      @closed = true
      @lock.synchronize do
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

    # The engine reaps a session once it has been idle long enough and then
    # quietly builds a fresh one for the id we keep sending, losing the database
    # and schema we selected. Nothing in the reply gives it away — the id we
    # sent is echoed back either way, and /api/sessions reports only a count —
    # so past the limit the only safe reading is that the session is new, and
    # the DSN's defaults go back on. Not once the caller has selected something
    # themselves: putting our defaults over their choice is its own surprise.
    def restore_session_defaults
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

    def round_trip(sql)
      @lock.synchronize do
        payload = { "sql" => sql, "autoCommit" => @autocommit }
        payload["sessionId"] = @session_id if @session_id
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
        @session_id = out["sessionId"] if out["sessionId"]
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
        { name: c["name"], data_type: c["dataType"], scale: c["scale"] }
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
        when "TIMESTAMP", "TIMESTAMP_NTZ", "TIMESTAMP_LTZ", "TIMESTAMP_TZ", "DATETIME"
          value.is_a?(String) ? Time.parse(value) : value
        when "BINARY", "VARBINARY"
          value.is_a?(String) ? decode_hex(value) : value
        else
          convert_number(value, (data_type || "").upcase, scale)
        end
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
