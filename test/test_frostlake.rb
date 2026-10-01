# frozen_string_literal: true

require "minitest/autorun"
require "net/http"
require "socket"

require_relative "../lib/frostlake"
require_relative "../testkit_runner"

# Boots a real DatabaseHttpServer from FROSTLAKE_CLASSPATH; the integration
# tests skip themselves when the variable is unset.
classpath = ENV.fetch("FROSTLAKE_CLASSPATH", nil)
SERVER_DSN = if classpath.nil? || classpath.empty?
  nil
else
  java_home = ENV.fetch("JAVA_HOME", nil)
  java = java_home ? File.join(java_home, "bin", "java") : "java"
  probe = TCPServer.new("127.0.0.1", 0)
  port = probe.addr[1]
  probe.close
  pid = Process.spawn(java, "-cp", classpath, "dev.frostlake.http.DatabaseHttpServer", port.to_s,
                      out: File::NULL, err: File::NULL)
  # minitest/autorun runs the suite from its own at_exit hook, and at_exit is
  # LIFO — a plain at_exit registered here would kill the server BEFORE the
  # tests run. Minitest.after_run fires after the suite finishes.
  Minitest.after_run do
    Process.kill("TERM", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
  healthy = false
  100.times do
    begin
      response = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/api/health"))
      if response.is_a?(Net::HTTPSuccess)
        healthy = true
        break
      end
    rescue SystemCallError
      # not up yet
    end
    sleep 0.2
  end
  raise "Frostlake server did not become healthy" unless healthy

  "frostlake://127.0.0.1:#{port}"
end

class SubstitutionTest < Minitest::Test
  def test_skips_literals_identifiers_and_comments
    rendered = Frostlake::Connection.substitute(
      "SELECT 'a?b', \"c?d\", ? -- e?f\n, ? /* g?h */", ["x", 2]
    )
    assert_equal "SELECT 'a?b', \"c?d\", 'x' -- e?f\n, 2 /* g?h */", rendered
  end

  def test_encodes_backslashes_then_quotes
    rendered = Frostlake::Connection.substitute("SELECT ?", ["Ada O'Hara \\ Byron"])
    assert_equal "SELECT 'Ada O''Hara \\\\ Byron'", rendered
  end

  def test_formats_typed_literals
    assert_equal "NULL", Frostlake::Connection.format_literal(nil)
    assert_equal "TRUE", Frostlake::Connection.format_literal(true)
    assert_equal "9.5", Frostlake::Connection.format_literal(9.5)
    assert_equal "X'CAFE'", Frostlake::Connection.format_literal((+"\xCA\xFE").force_encoding(Encoding::ASCII_8BIT))
    assert_equal "'2026-01-02T03:04:05.000000+05:00'::TIMESTAMP_TZ",
                 Frostlake::Connection.format_literal(Time.new(2026, 1, 2, 3, 4, 5, "+05:00"))
    assert_equal "'2026-01-02'::DATE", Frostlake::Connection.format_literal(Date.new(2026, 1, 2))
    assert_equal "[1, 'a']", Frostlake::Connection.format_literal([1, "a"])
  end

  def test_skips_double_slash_comments
    assert_equal "SELECT 1 // keep ? here\n, 2",
                 Frostlake::Connection.substitute("SELECT ? // keep ? here\n, ?", [1, 2])
  end

  def test_surplus_bind_values_are_ignored
    # Matching Frostlake's other drivers: too few raises, too many does not.
    assert_equal "SELECT 1", Frostlake::Connection.substitute("SELECT ?", [1, 2, 3])
  end

  def test_formats_the_remaining_types
    assert_equal "FALSE", Frostlake::Connection.format_literal(false)
    assert_equal "42", Frostlake::Connection.format_literal(42)
    assert_equal "'sym'", Frostlake::Connection.format_literal(:sym)
    assert_equal "[1, [2, 'x']]", Frostlake::Connection.format_literal([1, [2, "x"]])
  end

  def test_bigdecimal_binds_keep_their_digits
    skip "bigdecimal is not available" unless defined?(BigDecimal)

    assert_equal "1.5", Frostlake::Connection.format_literal(BigDecimal("1.50"))
    assert_equal "0.1234567891", Frostlake::Connection.format_literal(BigDecimal("0.1234567891"))
  end

  def test_leaves_dollar_quoted_bodies_alone
    rendered = Frostlake::Connection.substitute(
      "CREATE FUNCTION f() RETURNS STRING LANGUAGE JAVASCRIPT AS $$ return (1 ? 2 : 3) $$ WHERE x = ?", [7]
    )
    assert_includes rendered, "$$ return (1 ? 2 : 3) $$"
    assert_includes rendered, "WHERE x = 7"
  end

  def test_unterminated_dollar_quote_swallows_the_rest
    rendered = Frostlake::Connection.substitute("SELECT ?, $$ tail ?", [1])
    assert_equal "SELECT 1, $$ tail ?", rendered
  end
end

# The engine reports DML as a row of "number of ..." counters: one for INSERT and
# DELETE, two for UPDATE and MERGE.
class DmlStatusTest < Minitest::Test
  UPDATE_COLUMNS = [{ name: "number of rows updated" },
                    { name: "number of multi-joined rows updated" }].freeze
  MERGE_COLUMNS = [{ name: "number of rows inserted" },
                   { name: "number of rows updated" }].freeze

  def test_recognises_counter_shapes_and_ignores_data
    assert Frostlake::Connection.dml_status?(UPDATE_COLUMNS)
    assert Frostlake::Connection.dml_status?(MERGE_COLUMNS)
    refute Frostlake::Connection.dml_status?([{ name: "ID" }, { name: "NAME" }])
    refute Frostlake::Connection.dml_status?([])
  end

  def test_multi_joined_count_is_not_added_twice
    assert_equal 2, Frostlake::Connection.dml_row_count(
      UPDATE_COLUMNS, [2, 0]
    )
  end

  def test_merge_sums_its_inserted_and_updated_counts
    assert_equal 2, Frostlake::Connection.dml_row_count(
      MERGE_COLUMNS, [1, 1]
    )
  end
end

class ConnectFailureTest < Minitest::Test
  def test_unresolvable_host_raises_a_driver_error
    error = assert_raises(Frostlake::Error) do
      Frostlake.connect("frostlake://frostlake-no-such-host.invalid:18082/DB")
    end
    assert_includes error.message, "cannot reach"
  end
end

class ConnectionOptionTest < Minitest::Test
  def test_timeouts_default_and_come_from_the_dsn_or_a_keyword
    default = Frostlake::Connection.new("frostlake://example.invalid")
    assert_equal Frostlake::DEFAULT_OPEN_TIMEOUT, http(default).open_timeout
    assert_equal Frostlake::DEFAULT_READ_TIMEOUT, http(default).read_timeout

    from_dsn = Frostlake::Connection.new("frostlake://example.invalid/?open_timeout=3&read_timeout=7")
    assert_in_delta 3, http(from_dsn).open_timeout, 0.001
    assert_in_delta 7, http(from_dsn).read_timeout, 0.001

    # An explicit argument outranks the DSN.
    both = Frostlake::Connection.new("frostlake://example.invalid/?read_timeout=7", read_timeout: 9)
    assert_in_delta 9, http(both).read_timeout, 0.001
  end

  def test_a_nonsense_timeout_is_refused
    assert_raises(Frostlake::UsageError) do
      Frostlake::Connection.new("frostlake://example.invalid", read_timeout: "soon")
    end
    assert_raises(Frostlake::UsageError) do
      Frostlake::Connection.new("frostlake://example.invalid", open_timeout: -1)
    end
  end

  def test_scheme_decides_tls_and_the_default_port
    plain = Frostlake::Connection.new("frostlake://example.invalid/DB")
    refute http(plain).use_ssl?
    assert_equal Frostlake::DEFAULT_PORT, http(plain).port

    secure = Frostlake::Connection.new("https://example.invalid/DB")
    assert http(secure).use_ssl?
    assert_equal 443, http(secure).port
  end

  def test_a_dsn_the_driver_cannot_use_is_refused
    assert_raises(Frostlake::UsageError) { Frostlake::Connection.new("ftp://example.invalid/DB") }
    assert_raises(Frostlake::UsageError) { Frostlake::Connection.new("frostlake:///DB") }
  end

  def test_boolean_options_accept_the_usual_spellings
    %w[true yes 1].each do |yes|
      assert Frostlake::Connection.boolean_for("x", nil, yes, false), yes
    end
    %w[false no 0].each do |no|
      refute Frostlake::Connection.boolean_for("x", nil, no, true), no
    end
    assert_equal :fallback, Frostlake::Connection.boolean_for("x", nil, nil, :fallback)
    assert_raises(Frostlake::UsageError) do
      Frostlake::Connection.boolean_for("x", nil, "maybe", true)
    end
  end

  def test_a_port_outside_the_legal_range_is_refused
    assert_raises(Frostlake::UsageError) do
      Frostlake::Connection.new("frostlake://example.invalid:99999/DB")
    end
  end

  def test_credentials_in_the_dsn_are_refused
    # The server authenticates nobody, so silently dropping them would be worse.
    assert_raises(Frostlake::UsageError) do
      Frostlake::Connection.new("frostlake://someone:secret@example.invalid/DB")
    end
  end

  def test_tls_verification_can_be_configured
    begin
      require "openssl"
    rescue LoadError
      skip "openssl is not available"
    end

    strict = Frostlake::Connection.new("https://example.invalid/DB")
    assert_equal OpenSSL::SSL::VERIFY_PEER, http(strict).verify_mode

    from_dsn = Frostlake::Connection.new("https://example.invalid/DB?verify_ssl=false")
    assert_equal OpenSSL::SSL::VERIFY_NONE, http(from_dsn).verify_mode

    with_authority = Frostlake::Connection.new("https://example.invalid/DB", ca_file: "/tmp/ca.pem")
    assert_equal "/tmp/ca.pem", http(with_authority).ca_file
  end

  def test_tls_options_are_refused_where_they_would_do_nothing
    assert_raises(Frostlake::UsageError) do
      Frostlake::Connection.new("frostlake://example.invalid/DB", verify_ssl: false)
    end
    # However they were spelled: ignoring the DSN form was the bug.
    assert_raises(Frostlake::UsageError) do
      Frostlake::Connection.new("frostlake://example.invalid/DB?verify_ssl=false")
    end
    assert_raises(Frostlake::UsageError) do
      Frostlake::Connection.new("frostlake://example.invalid/DB?ca_file=/tmp/ca.pem")
    end
    assert_raises(Frostlake::UsageError) do
      Frostlake::Connection.new("https://example.invalid/DB", verify_ssl: "maybe")
    end
  end

  def test_unknown_dsn_parameters_are_refused
    # A typo in schema or read_timeout would otherwise change behaviour silently.
    error = assert_raises(Frostlake::UsageError) do
      Frostlake::Connection.new("frostlake://example.invalid/DB?scheam=PUBLIC")
    end
    assert_match(/scheam/, error.message)
    assert_raises(Frostlake::UsageError) do
      Frostlake::Connection.new("frostlake://example.invalid/DB?nonsense=1")
    end
    # The documented ones still pass.
    Frostlake::Connection.new(
      "frostlake://example.invalid/DB?schema=S&open_timeout=1&read_timeout=2"
    )
  end

  def test_the_dsn_path_names_one_database
    error = assert_raises(Frostlake::UsageError) do
      Frostlake::Connection.new("frostlake://example.invalid/db/extra")
    end
    assert_match(%r{db/extra}, error.message)
    # A trailing slash is just a trailing slash.
    trailing = Frostlake::Connection.new("frostlake://example.invalid/db/")
    assert_equal ['USE DATABASE "DB"'], trailing.instance_variable_get(:@pending_use)
  end

  private

  def http(connection)
    connection.instance_variable_get(:@http)
  end
end

class ErrorHierarchyTest < Minitest::Test
  def test_every_error_is_still_a_frostlake_error
    assert Frostlake::ConnectionError < Frostlake::Error
    assert Frostlake::QueryError < Frostlake::Error
    assert Frostlake::UsageError < Frostlake::Error
  end

  def test_driver_misuse_raises_usage_error
    assert_raises(Frostlake::UsageError) { Frostlake::Connection.substitute("SELECT ?", []) }
    assert_raises(Frostlake::UsageError) { Frostlake::Connection.format_literal(Object.new) }
    assert_raises(Frostlake::UsageError) { Frostlake::Connection.format_literal(Float::INFINITY) }
  end
end

# Runs the block as a host in the named zone would: the process's local zone is
# that one until the block ends, and whatever it was before afterwards.
module LocalZone
  def in_local_zone(zone)
    saved = ENV.fetch("TZ", nil)
    ENV["TZ"] = zone
    yield
  ensure
    ENV["TZ"] = saved
  end
end

class ConversionTest < Minitest::Test
  include LocalZone

  def test_fixed_point_keeps_its_digits_and_floats_stay_floats
    skip "bigdecimal is not available" unless defined?(BigDecimal)

    exact = Frostlake::Connection.convert(BigDecimal("0.1234567891"), "NUMBER", 10)
    assert_instance_of BigDecimal, exact
    assert_equal "0.1234567891", exact.to_s("F")

    # An approximate column is a real binary float and must not pretend otherwise.
    assert_instance_of Float, Frostlake::Connection.convert(BigDecimal("1.5"), "FLOAT", 0)
    # Scale 0 is an integer column.
    assert_equal 42, Frostlake::Connection.convert(BigDecimal("42"), "NUMBER", 0)
    assert_instance_of Integer, Frostlake::Connection.convert(BigDecimal("42"), "NUMBER", 0)
    # A fraction at scale 0 is unexpected, but truncating it silently would be worse.
    assert_instance_of BigDecimal, Frostlake::Connection.convert(BigDecimal("1.5"), "NUMBER", 0)
  end

  def test_binary_that_is_not_hex_is_handed_back_untouched
    assert_equal (+"\xCA\xFE").force_encoding(Encoding::ASCII_8BIT),
                 Frostlake::Connection.convert("CAFE", "BINARY")
    # pack("H*") would turn these into bytes rather than admit the problem.
    assert_equal "ZZ", Frostlake::Connection.convert("ZZ", "BINARY")
    assert_equal "ABC", Frostlake::Connection.convert("ABC", "BINARY")
    assert_equal "", Frostlake::Connection.convert("", "BINARY")
  end

  def test_every_timestamp_flavour_becomes_a_time
    %w[TIMESTAMP TIMESTAMP_NTZ TIMESTAMP_LTZ TIMESTAMP_TZ DATETIME].each do |type|
      assert_instance_of Time, Frostlake::Connection.convert("2026-08-13 12:34:56", type), type
    end
  end

  # A TIMESTAMP_NTZ is a wall clock with no zone. London skips 01:00-02:00 on
  # 2024-03-31, so a local Time cannot hold 01:30 there: it becomes 02:30 BST.
  def test_an_ntz_cell_keeps_a_wall_clock_the_local_zone_skips
    in_local_zone("Europe/London") do
      %w[TIMESTAMP_NTZ TIMESTAMP DATETIME].each do |type|
        decoded = Frostlake::Connection.convert("2024-03-31 01:30:00.123456789", type)
        assert_equal "2024-03-31 01:30:00.123456789", decoded.strftime("%F %T.%N"), type
        # UTC skips nothing, so every host reads the same fields.
        assert_predicate decoded, :utc?, type
      end
      # The zoned types carry an offset on the wire, and keep it.
      %w[TIMESTAMP_LTZ TIMESTAMP_TZ].each do |type|
        decoded = Frostlake::Connection.convert("2024-03-31 01:30:00.000 +0500", type)
        assert_equal Time.utc(2024, 3, 30, 20, 30), decoded, type
        assert_equal 18_000, decoded.utc_offset, type
      end
    end
  end

  def test_values_the_driver_deliberately_leaves_alone
    # TIME and semi-structured cells keep their wire shape.
    assert_equal "12:34:56", Frostlake::Connection.convert("12:34:56", "TIME")
    assert_equal '{"k":1}', Frostlake::Connection.convert('{"k":1}', "OBJECT")
    assert_equal "[1,2]", Frostlake::Connection.convert("[1,2]", "ARRAY")
    assert_equal true, Frostlake::Connection.convert(true, "BOOLEAN")
    assert_equal "text", Frostlake::Connection.convert("text", "VARCHAR")
  end

  def test_temporal_and_binary_columns
    assert_equal Date.new(2026, 8, 13), Frostlake::Connection.convert("2026-08-13", "DATE")
    assert_instance_of Time, Frostlake::Connection.convert("2026-08-13 12:34:56", "TIMESTAMP_NTZ")
    assert_equal (+"\xCA\xFE").force_encoding(Encoding::ASCII_8BIT),
                 Frostlake::Connection.convert("CAFE", "BINARY")
    assert_nil Frostlake::Connection.convert(nil, "NUMBER", 10)
  end

  def test_json_is_parsed_without_rounding
    skip "bigdecimal is not available" unless defined?(BigDecimal)

    parsed = Frostlake::Connection.parse_json('{"n": 0.1234567891234567891}')
    assert_equal "0.1234567891234567891", parsed["n"].to_s("F")
  end
end

class QuoteIdentTest < Minitest::Test
  def test_every_identifier_is_quoted
    assert_equal '"PLAIN"', Frostlake::Connection.quote_ident("PLAIN")
    assert_equal '"lower"', Frostlake::Connection.quote_ident("lower")
    assert_equal '"with space"', Frostlake::Connection.quote_ident("with space")
  end

  def test_names_that_cannot_appear_unquoted
    # An unquoted identifier may not start with a digit, and SELECT is reserved.
    assert_equal '"1ABC"', Frostlake::Connection.quote_ident("1ABC")
    assert_equal '"9"', Frostlake::Connection.quote_ident("9")
    assert_equal '"SELECT"', Frostlake::Connection.quote_ident("SELECT")
  end

  def test_an_embedded_quote_is_doubled
    assert_equal '"has""quote"', Frostlake::Connection.quote_ident('has"quote')
  end

  def test_an_empty_identifier_is_refused
    assert_raises(Frostlake::UsageError) { Frostlake::Connection.quote_ident("") }
  end
end

class UseIdentTest < Minitest::Test
  # A DSN name is a SQL identifier: plain names fold, the rest keep their case.
  def test_plain_names_fold_to_upper_case
    assert_equal '"MY_DB"', Frostlake::Connection.use_ident("my_db")
    assert_equal '"MIXED"', Frostlake::Connection.use_ident("Mixed")
    assert_equal '"SELECT"', Frostlake::Connection.use_ident("select")
  end

  def test_other_names_are_quoted_as_given
    assert_equal '"with space"', Frostlake::Connection.use_ident("with space")
    assert_equal '"1abc"', Frostlake::Connection.use_ident("1abc")
    assert_equal '"has""quote"', Frostlake::Connection.use_ident('has"quote')
  end
end

class ResultTest < Minitest::Test
  # A self-join reports the same name twice.
  COLUMNS = [{ name: "ID" }, { name: "NAME" }, { name: "ID" }].freeze

  def test_rows_are_built_from_values_and_kept
    result = Frostlake::Result.new(COLUMNS, 1, [[1, "Ada", 2]])
    assert_equal [[1, "Ada", 2]], result.values
    # The later ID wins in the hash; values still has both.
    assert_equal({ "ID" => 2, "NAME" => "Ada" }, result.rows.first)
    assert_same result.rows, result.rows
  end

  def test_rows_is_built_once_even_from_several_threads
    result = Frostlake::Result.new([{ name: "A" }], 2, [[1], [2]])
    seen = Queue.new
    8.times.map { Thread.new { seen << result.rows.object_id } }.each(&:join)
    ids = []
    ids << seen.pop until seen.empty?
    assert_equal 1, ids.uniq.length
  end

  def test_it_enumerates_the_named_rows
    result = Frostlake::Result.new([{ name: "A" }], 2, [[1], [2]])
    assert_equal [1, 2], result.map { |row| row["A"] }
    assert_equal 2, result.count
    assert_equal({ "A" => 1 }, result.first)
  end
end

class DeadServerTest < Minitest::Test
  def test_a_statement_with_nothing_listening_raises_connection_error
    # Port 1 has no server; Connection.new does not connect, so this is the
    # first time the socket is used.
    conn = Frostlake::Connection.new("frostlake://127.0.0.1:1/DB", open_timeout: 1)
    assert_raises(Frostlake::ConnectionError) { conn.execute("SELECT 1") }
  end
end

class SessionIdleTest < Minitest::Test
  def test_it_notices_the_caller_selecting_session_state
    assert Frostlake::Connection.selects_session_state?("USE DATABASE X")
    assert Frostlake::Connection.selects_session_state?("  use schema s")
    assert Frostlake::Connection.selects_session_state?("SELECT 1; USE WAREHOUSE W")
    assert Frostlake::Connection.selects_session_state?("-- first\nUSE DATABASE X")
    # A mention of USE inside a literal is not a USE.
    refute Frostlake::Connection.selects_session_state?("SELECT 'USE DATABASE X'")
  end

  def test_the_idle_limit_is_validated
    assert_equal Frostlake::DEFAULT_SESSION_IDLE_LIMIT,
                 Frostlake::Connection.idle_limit_for(nil, nil)
    assert_equal 0, Frostlake::Connection.idle_limit_for(0, nil)
    assert_in_delta 5, Frostlake::Connection.idle_limit_for(nil, "5"), 0.001
    assert_raises(Frostlake::UsageError) { Frostlake::Connection.idle_limit_for("soon", nil) }
    assert_raises(Frostlake::UsageError) { Frostlake::Connection.idle_limit_for(-5, nil) }
  end
end

# Stands in for a connection's Net::HTTP and keeps the request bodies it was
# handed; there is no mocking library here.
class PayloadRecorder
  Reply = Struct.new(:body)

  attr_reader :payloads

  def initialize
    @payloads = []
  end

  def request(request)
    @payloads << JSON.parse(request.body)
    Reply.new('{"success":true,"resultSets":[]}')
  end

  def started?
    false
  end
end

class MultiStatementCountTest < Minitest::Test
  def recording_connection
    conn = Frostlake::Connection.new("frostlake://127.0.0.1:1")
    recorder = PayloadRecorder.new
    conn.instance_variable_set(:@http, recorder)
    [conn, recorder]
  end

  def test_the_field_is_absent_unless_the_call_asks_for_a_count
    conn, recorder = recording_connection
    conn.execute("SELECT 1")
    conn.execute_all("SELECT 1; SELECT 2", [], multi_statement_count: nil)
    assert_equal 2, recorder.payloads.length
    recorder.payloads.each { |payload| refute_includes payload.keys, "multiStatementCount" }
  end

  def test_a_declared_count_rides_on_that_request_alone
    conn, recorder = recording_connection
    conn.execute("SELECT 1; SELECT 2", [], multi_statement_count: 2)
    conn.execute_all("SELECT 1; SELECT 2; SELECT 3", [], multi_statement_count: 0)
    conn.execute("SELECT 1")
    # 0 is a count like any other — any number — not an absent one.
    assert_equal [2, 0], recorder.payloads.first(2).map { |payload| payload["multiStatementCount"] }
    refute_includes recorder.payloads[2].keys, "multiStatementCount"
    # Nothing alters session state to carry it.
    refute(recorder.payloads.any? { |payload| payload["sql"].include?("ALTER SESSION") })
  end

  def test_a_count_that_is_not_a_whole_number_of_statements_is_refused
    conn, = recording_connection
    assert_raises(Frostlake::UsageError) { conn.execute("SELECT 1", [], multi_statement_count: -1) }
    assert_raises(Frostlake::UsageError) { conn.execute("SELECT 1", [], multi_statement_count: "2") }
  end
end

# Stands in for a connection's Net::HTTP: answers every request from a script
# and keeps what it was sent. A request the script did not expect fails the
# test, so every round trip a scenario makes is one it scripted.
class ScriptedHttp
  Reply = Struct.new(:code, :body)
  Sent = Struct.new(:verb, :path, :payload)

  attr_accessor :open_timeout, :read_timeout, :write_timeout, :max_retries
  attr_reader :sent

  def initialize
    @script = []
    @sent = []
    @open_timeout = Frostlake::DEFAULT_OPEN_TIMEOUT
    @read_timeout = Frostlake::DEFAULT_READ_TIMEOUT
    @write_timeout = 60
    @max_retries = 1
  end

  # The answer to the next request, with the status it arrives under.
  def reply(body, status: 200)
    @script << Reply.new(status.to_s, body)
    self
  end

  # What the next request raises instead of being answered, as Net::HTTP does.
  def fail_with(error)
    @script << error
    self
  end

  def request(request)
    @sent << Sent.new(request.method, request.path, request.body.nil? ? nil : JSON.parse(request.body))
    # Not a StandardError, so no rescue in the driver can swallow it.
    raise Minitest::Assertion, "unscripted request: #{request.method} #{request.path}" if @script.empty?

    step = @script.shift
    raise step if step.is_a?(Exception)

    step
  end

  def started?
    false
  end

  def pending
    @script.length
  end

  def executes
    @sent.select { |sent| sent.path == "/api/execute" }
  end

  # The SQL of every POST /api/execute, in order.
  def statements
    executes.map { |sent| sent.payload["sql"] }
  end
end

# Answers worded as the engine words them.
module ScriptedAnswers
  OK = { "columns" => [{ "dataType" => "VARCHAR", "name" => "status" }],
         "rows" => [["Statement executed successfully."]], "rowCount" => 1, "updateCount" => -1 }.freeze

  RELEASED = JSON.generate("success" => true, "sessionId" => nil, "newSession" => false,
                           "errorMessage" => nil, "executionTimeMs" => 0, "resultSets" => [])

  def number_set(name, value)
    { "columns" => [{ "dataType" => "NUMBER", "name" => name, "precision" => 38, "scale" => 0 }],
      "rows" => [[value]], "rowCount" => 1, "updateCount" => -1 }
  end

  # From an engine that reports newSession, as 0.1.0 and later do.
  def answer(session_id, started, sets = [OK])
    JSON.generate("success" => true, "sessionId" => session_id, "newSession" => started,
                  "errorMessage" => nil, "executionTimeMs" => 1, "resultSets" => sets)
  end

  # From an engine that predates newSession, requireSession and the release.
  def legacy_answer(session_id, sets = [OK])
    JSON.generate("success" => true, "sessionId" => session_id, "errorMessage" => nil,
                  "executionTimeMs" => 1, "resultSets" => sets)
  end

  def refused(session_id, message)
    JSON.generate("success" => false, "sessionId" => session_id, "newSession" => false,
                  "errorMessage" => message, "executionTimeMs" => 0, "resultSets" => [])
  end

  # The 404 a request that requires its session gets once the session is gone.
  def session_gone(session_id)
    JSON.generate("success" => false, "sessionId" => nil, "newSession" => false,
                  "errorMessage" => "Session '#{session_id}' does not exist or has expired.",
                  "executionTimeMs" => 0, "resultSets" => [])
  end
end

# How a connection keeps its idea of the engine session in step with the
# engine's, over a scripted Net::HTTP.
class SessionRecoveryTest < Minitest::Test
  include ScriptedAnswers

  DSN = "frostlake://scripted:18082/APP?schema=PUBLIC"
  SCOPE = ['USE DATABASE "APP"', 'USE SCHEMA "PUBLIC"'].freeze

  def scripted(dsn = DSN)
    http = ScriptedHttp.new
    conn = Frostlake::Connection.new(dsn)
    conn.instance_variable_set(:@http, http)
    [conn, http]
  end

  # A connection whose DSN scope went onto session s1 of an engine that
  # reports newSession.
  def opened
    conn, http = scripted
    http.reply(answer("s1", true)).reply(answer("s1", false))
    conn.use_dsn_defaults
    [conn, http]
  end

  # A connection on an engine that predates newSession.
  def opened_on_an_older_engine
    conn, http = scripted
    http.reply(legacy_answer("old1")).reply(legacy_answer("old1"))
    conn.use_dsn_defaults
    [conn, http]
  end

  def test_require_session_waits_until_the_engine_says_it_tracks_sessions
    conn, http = opened
    first, second = http.executes
    # The first request names no session, so there is nothing to require yet.
    refute_includes first.payload.keys, "sessionId"
    refute_includes first.payload.keys, "requireSession"
    # Its answer carried newSession: every request from then on requires its session.
    assert_equal "s1", second.payload["sessionId"]
    assert_equal true, second.payload["requireSession"]
    http.reply(answer("s1", false, [number_set("N", 1)]))
    assert_equal [{ "N" => 1 }], conn.execute("SELECT 1 AS N").rows
    assert_equal ["s1", true], http.executes.last.payload.values_at("sessionId", "requireSession")
  end

  def test_an_older_engine_is_sent_neither_require_session_nor_a_release
    conn, http = opened_on_an_older_engine
    http.reply(legacy_answer("old1", [number_set("N", 1)]))
    conn.execute("SELECT 1 AS N")
    assert_equal [nil, "old1", "old1"], http.executes.map { |sent| sent.payload["sessionId"] }
    http.sent.each { |sent| refute_includes sent.payload.keys, "requireSession" }
    conn.close
    assert_equal 3, http.sent.length
  end

  def test_a_lost_session_is_replaced_on_the_dsn_scope_and_the_statement_sent_once_more
    conn, http = opened
    http.reply(session_gone("s1"), status: 404)
    http.reply(answer("s2", true)).reply(answer("s2", false))
    http.reply(answer("s2", false, [number_set("N", 1)]))
    assert_equal [{ "N" => 1 }], conn.execute("SELECT 1 AS N").rows
    assert_equal SCOPE + ["SELECT 1 AS N"] + SCOPE + ["SELECT 1 AS N"], http.statements
    # The scope went onto a fresh session: its first request named none.
    refute_includes http.executes[3].payload.keys, "sessionId"
    assert_equal ["s2", "s2"], http.executes.last(2).map { |sent| sent.payload["sessionId"] }
    assert_equal 0, http.pending
  end

  def test_a_second_refusal_raises_instead_of_trying_again
    conn, http = opened
    http.reply(session_gone("s1"), status: 404)
    http.reply(answer("s2", true)).reply(answer("s2", false))
    http.reply(session_gone("s2"), status: 404)
    assert_raises(Frostlake::SessionLostError) { conn.execute("SELECT 1 AS N") }
    assert_equal SCOPE + ["SELECT 1 AS N"] + SCOPE + ["SELECT 1 AS N"], http.statements
    assert_equal 0, http.pending
  end

  def test_a_lost_session_with_an_open_transaction_is_reported_not_replaced
    conn, http = opened
    http.reply(answer("s1", false))
    conn.begin_transaction
    http.reply(session_gone("s1"), status: 404)
    error = assert_raises(Frostlake::SessionLostError) { conn.execute("INSERT INTO t VALUES (1)") }
    assert_match(/transaction/, error.message)
    assert_kind_of Frostlake::ConnectionError, error
    assert_equal SCOPE + ["BEGIN", "INSERT INTO t VALUES (1)"], http.statements
    # The connection stays usable: the next statement starts over on the
    # DSN's scope, outside any transaction.
    http.reply(answer("s2", true)).reply(answer("s2", false))
    http.reply(answer("s2", false, [number_set("N", 1)]))
    conn.execute("SELECT 1 AS N")
    assert_equal SCOPE + ["SELECT 1 AS N"], http.statements.last(3)
    refute_includes http.executes[-3].payload.keys, "sessionId"
    assert_equal true, http.executes.last.payload["autoCommit"]
    assert_equal 0, http.pending
  end

  def test_a_begin_that_meets_a_lost_session_opens_the_transaction_on_the_fresh_one
    conn, http = opened
    http.reply(session_gone("s1"), status: 404)
    http.reply(answer("s2", true)).reply(answer("s2", false)).reply(answer("s2", false))
    conn.begin_transaction
    assert_equal SCOPE + ["BEGIN"] + SCOPE + ["BEGIN"], http.statements
    assert_equal false, http.executes.last.payload["autoCommit"]
    # Now it holds a transaction, so losing this session too is reported.
    http.reply(session_gone("s2"), status: 404)
    assert_raises(Frostlake::SessionLostError) { conn.execute("INSERT INTO t VALUES (1)") }
    assert_equal 0, http.pending
  end

  def test_a_transaction_opened_by_a_statement_is_tracked_until_it_ends
    conn, http = opened
    http.reply(answer("s1", false))
    conn.execute("begin transaction")
    http.reply(session_gone("s1"), status: 404)
    assert_raises(Frostlake::SessionLostError) { conn.execute("SELECT 1 AS N") }

    conn, http = opened
    http.reply(answer("s1", false)).reply(answer("s1", false))
    conn.execute("START TRANSACTION")
    conn.execute("COMMIT")
    http.reply(session_gone("s1"), status: 404)
    http.reply(answer("s2", true)).reply(answer("s2", false))
    http.reply(answer("s2", false, [number_set("N", 1)]))
    assert_equal [{ "N" => 1 }], conn.execute("SELECT 1 AS N").rows
  end

  def test_a_lost_session_whose_context_moved_is_reported_not_replaced
    conn, http = opened
    http.reply(answer("s1", false))
    conn.execute("USE SCHEMA OTHER")
    http.reply(session_gone("s1"), status: 404)
    error = assert_raises(Frostlake::SessionLostError) { conn.execute("SELECT * FROM t") }
    assert_match(/context/, error.message)
    assert_equal SCOPE + ["USE SCHEMA OTHER", "SELECT * FROM t"], http.statements
    assert_equal 0, http.pending
    # Then back on the DSN's scope, not the schema the lost session had moved to.
    http.reply(answer("s2", true)).reply(answer("s2", false))
    http.reply(answer("s2", false, [number_set("N", 1)]))
    conn.execute("SELECT 1 AS N")
    assert_equal SCOPE + ["SELECT 1 AS N"], http.statements.last(3)
  end

  def test_session_state_is_noticed_anywhere_in_a_request
    ["SET x = 1", "ALTER SESSION SET TIMEZONE = 'UTC'", "CREATE TEMPORARY TABLE t (a INT)",
     "CREATE DATABASE other", "UNSET x"].each do |statement|
      conn, http = opened
      http.reply(answer("s1", false, [number_set("N", 1), OK]))
      conn.execute_all("SELECT 1 AS N; #{statement}", [], multi_statement_count: 2)
      http.reply(session_gone("s1"), status: 404)
      assert_raises(Frostlake::SessionLostError, statement) { conn.execute("SELECT 2") }
      assert_equal 0, http.pending, statement
    end
  end

  def test_a_refused_statement_leaves_the_session_as_it_was
    conn, http = opened
    http.reply(refused("s1", "Schema 'NOPE' does not exist or not authorized."))
    assert_raises(Frostlake::QueryError) { conn.execute("USE SCHEMA NOPE") }
    http.reply(session_gone("s1"), status: 404)
    http.reply(answer("s2", true)).reply(answer("s2", false))
    http.reply(answer("s2", false, [number_set("N", 1)]))
    assert_equal [{ "N" => 1 }], conn.execute("SELECT 1 AS N").rows
  end

  def test_a_scope_that_fails_on_the_fresh_session_stays_pending_in_full
    conn, http = opened
    http.reply(session_gone("s1"), status: 404)
    http.reply(refused("s2", "Database 'APP' does not exist or not authorized."))
    assert_raises(Frostlake::QueryError) { conn.execute("SELECT 1 AS N") }
    # Not USE SCHEMA alone: the next statement puts the whole scope on first.
    http.reply(answer("s2", false)).reply(answer("s2", false))
    http.reply(answer("s2", false, [number_set("N", 1)]))
    conn.execute("SELECT 1 AS N")
    assert_equal SCOPE + ["SELECT 1 AS N", SCOPE.first] + SCOPE + ["SELECT 1 AS N"], http.statements
  end

  def test_a_session_the_engine_replaced_gets_its_scope_back_before_the_next_statement
    conn, http = opened
    http.reply(answer("s1", true, [number_set("N", 1)]))
    conn.execute("SELECT 1 AS N")
    http.reply(answer("s1", false)).reply(answer("s1", false))
    http.reply(answer("s1", false, [number_set("N", 2)]))
    conn.execute("SELECT 2 AS N")
    assert_equal SCOPE + ["SELECT 1 AS N"] + SCOPE + ["SELECT 2 AS N"], http.statements
  end

  def test_with_no_scope_in_the_dsn_the_statement_itself_starts_the_fresh_session
    conn, http = scripted("frostlake://scripted:18082")
    http.reply(answer("n1", true, [number_set("N", 1)]))
    conn.execute("SELECT 1 AS N")
    http.reply(session_gone("n1"), status: 404).reply(answer("n2", true, [number_set("N", 1)]))
    conn.execute("SELECT 1 AS N")
    assert_equal ["SELECT 1 AS N"] * 3, http.statements
    refute_includes http.executes.last.payload.keys, "sessionId"
  end

  def test_the_idle_rescope_is_kept_for_an_older_engine_only
    conn, http = opened_on_an_older_engine
    conn.instance_variable_set(:@last_used_at, -100_000)
    http.reply(legacy_answer("old1")).reply(legacy_answer("old1"))
    http.reply(legacy_answer("old1", [number_set("N", 1)]))
    conn.execute("SELECT 1 AS N")
    assert_equal SCOPE + SCOPE + ["SELECT 1 AS N"], http.statements

    # An engine that tracks sessions refuses one it no longer holds instead.
    conn, http = opened
    conn.instance_variable_set(:@last_used_at, -100_000)
    http.reply(answer("s1", false, [number_set("N", 1)]))
    conn.execute("SELECT 1 AS N")
    assert_equal SCOPE + ["SELECT 1 AS N"], http.statements
  end

  def test_closing_releases_the_session_once
    conn, http = opened
    http.reply(RELEASED)
    conn.close
    release = http.sent.last
    assert_equal ["DELETE", "/api/sessions/s1"], [release.verb, release.path]
    assert_equal 0, http.pending
    sent = http.sent.length
    conn.close
    assert_equal sent, http.sent.length
    assert_raises(Frostlake::UsageError) { conn.execute("SELECT 1") }
  end

  def test_closing_with_a_transaction_open_leaves_the_rollback_to_the_release
    conn, http = opened
    http.reply(answer("s1", false))
    conn.begin_transaction
    http.reply(RELEASED)
    conn.close
    assert_equal ["POST", "DELETE"], http.sent.last(2).map(&:verb)
    assert_equal 0, http.pending
  end

  def test_closing_never_raises_whatever_the_release_meets
    {
      "a session already gone" => [session_gone("s1"), 404],
      "an engine without the endpoint" => ["<html><body>405 Method Not Allowed</body></html>", 405],
      "a refused connection" => Errno::ECONNREFUSED.new,
      "a reset connection" => Errno::ECONNRESET.new,
      "a timeout" => Net::ReadTimeout.new
    }.each do |label, outcome|
      conn, http = opened
      if outcome.is_a?(Exception)
        http.fail_with(outcome)
      else
        http.reply(outcome[0], status: outcome[1])
      end
      conn.close
      assert_predicate conn, :closed?, label
      assert_equal "DELETE", http.sent.last.verb, label
      assert_equal 0, http.pending, label
    end
  end

  def test_the_release_is_bounded_when_the_engine_never_answers
    # A listener that takes every connection and never says a word.
    listener = TCPServer.new("127.0.0.1", 0)
    held = Queue.new
    acceptor = Thread.new { loop { held << listener.accept } }
    port = listener.addr[1]
    # The connection's own timeout, when it is the shorter...
    assert_operator releasing_takes("frostlake://127.0.0.1:#{port}/APP?read_timeout=0.3"), :<, 3
    # ...and the close budget, when that is.
    with_close_budget(0.3) do
      assert_operator releasing_takes("frostlake://127.0.0.1:#{port}/APP"), :<, 3
    end
    acceptor.kill.join
    listener.close
    # Nothing listening at all is no error either.
    assert_operator releasing_takes("frostlake://127.0.0.1:#{port}/APP"), :<, 3
  ensure
    acceptor&.kill&.join
    held&.pop&.close until held.nil? || held.empty?
    listener.close unless listener.nil? || listener.closed?
  end

  private

  # Closes a real connection holding session s1 of an engine that tracks
  # sessions, and answers how many seconds that took.
  def releasing_takes(dsn)
    conn = Frostlake::Connection.new(dsn, open_timeout: 1)
    conn.instance_variable_set(:@session_id, "s1")
    conn.instance_variable_set(:@tracks_sessions, true)
    started = Frostlake::Connection.monotonic_now
    conn.close
    assert_predicate conn, :closed?
    Frostlake::Connection.monotonic_now - started
  end

  def with_close_budget(seconds)
    saved = Frostlake::CLOSE_BUDGET
    Frostlake.send(:remove_const, :CLOSE_BUDGET)
    Frostlake.const_set(:CLOSE_BUDGET, seconds)
    yield
  ensure
    Frostlake.send(:remove_const, :CLOSE_BUDGET)
    Frostlake.const_set(:CLOSE_BUDGET, saved)
  end
end

# A begin that fails opens no transaction, so the connection stays in
# autocommit and the statements after it commit as they run. BEGIN itself goes
# out with autocommit off, over a scripted Net::HTTP.
class FailedBeginTest < Minitest::Test
  include ScriptedAnswers

  DSN = SessionRecoveryTest::DSN
  SCOPE = SessionRecoveryTest::SCOPE

  def scripted
    http = ScriptedHttp.new
    conn = Frostlake::Connection.new(DSN)
    conn.instance_variable_set(:@http, http)
    [conn, http]
  end

  # A connection whose DSN scope went onto session s1.
  def opened
    conn, http = scripted
    http.reply(answer("s1", true)).reply(answer("s1", false))
    conn.use_dsn_defaults
    [conn, http]
  end

  # The body the next statement goes out with, once its answer is scripted.
  def next_statement(conn, http, session = "s1")
    http.reply(answer(session, false, [number_set("N", 1)]))
    conn.execute("SELECT 1 AS N")
    http.executes.last.payload
  end

  def begins_sent(http)
    http.executes.select { |sent| sent.payload["sql"] == "BEGIN" }.map { |sent| sent.payload["autoCommit"] }
  end

  def test_a_begin_the_engine_refuses_leaves_autocommit_on
    conn, http = opened
    http.reply(refused("s1", "SQL compilation error:\nsyntax error line 1 at position 0 unexpected 'BEGIN'."))
    assert_raises(Frostlake::QueryError) { conn.begin_transaction }
    assert_equal [false], begins_sent(http)
    assert_equal true, next_statement(conn, http)["autoCommit"]
  end

  def test_a_begin_answered_with_an_unreadable_body_leaves_autocommit_on
    conn, http = opened
    http.reply("<html><body>502 Bad Gateway</body></html>", status: 502)
    assert_raises(Frostlake::ConnectionError) { conn.begin_transaction }
    assert_equal true, next_statement(conn, http)["autoCommit"]
  end

  def test_a_begin_the_server_hangs_up_on_leaves_autocommit_on
    conn, http = opened
    http.fail_with(EOFError.new("end of file reached"))
    assert_raises(Frostlake::ConnectionError) { conn.begin_transaction }
    assert_equal true, next_statement(conn, http)["autoCommit"]
  end

  def test_a_begin_behind_a_refused_use_is_never_sent_and_leaves_autocommit_on
    conn, http = scripted
    http.reply(refused("s1", "Database 'APP' does not exist or not authorized."))
    assert_raises(Frostlake::QueryError) { conn.begin_transaction }
    assert_equal [SCOPE.first], http.statements
    http.reply(answer("s1", false)).reply(answer("s1", false))
    next_statement(conn, http)
    assert_equal [SCOPE.first] + SCOPE + ["SELECT 1 AS N"], http.statements
    # Every request, the refused USE included, went out in autocommit.
    assert_equal [true] * 4, http.executes.map { |sent| sent.payload["autoCommit"] }
  end

  def test_a_begin_whose_lost_session_cannot_be_replaced_leaves_autocommit_on
    conn, http = opened
    http.reply(session_gone("s1"), status: 404)
    http.reply(answer("s2", true)).reply(answer("s2", false))
    http.reply(session_gone("s2"), status: 404)
    assert_raises(Frostlake::SessionLostError) { conn.begin_transaction }
    # Sent again on the fresh session, BEGIN still carried autocommit off.
    assert_equal [false, false], begins_sent(http)
    assert_equal true, next_statement(conn, http, "s2")["autoCommit"]
  end

  def test_a_begin_whose_lost_session_held_context_leaves_autocommit_on
    conn, http = opened
    http.reply(answer("s1", false))
    conn.execute("USE SCHEMA OTHER")
    http.reply(session_gone("s1"), status: 404)
    assert_raises(Frostlake::SessionLostError) { conn.begin_transaction }
    http.reply(answer("s2", true)).reply(answer("s2", false))
    assert_equal true, next_statement(conn, http, "s2")["autoCommit"]
  end

  def test_a_transaction_block_whose_begin_fails_leaves_autocommit_on
    conn, http = opened
    # BEGIN goes unanswered, and so does the ROLLBACK that makes up for it.
    http.fail_with(EOFError.new("end of file reached"))
    http.fail_with(Errno::ECONNREFUSED.new)
    ran = false
    assert_raises(Frostlake::ConnectionError) { conn.transaction { ran = true } }
    refute ran
    assert_equal ["BEGIN", "ROLLBACK"], http.statements.last(2)
    assert_equal true, next_statement(conn, http)["autoCommit"]
  end

  def test_a_begin_that_succeeds_turns_autocommit_off
    conn, http = opened
    http.reply(answer("s1", false))
    conn.begin_transaction
    assert_equal [false], begins_sent(http)
    assert_equal false, next_statement(conn, http)["autoCommit"]
  end
end

# How statements are read for what they leave on the session.
class SessionTrackingTest < Minitest::Test
  def test_requests_split_on_top_level_semicolons_only
    assert_equal ["SELECT 1", " SELECT ';'", " SELECT \";\""],
                 Frostlake::Connection.statements("SELECT 1; SELECT ';'; SELECT \";\";")
    assert_equal 1, Frostlake::Connection.statements("EXECUTE IMMEDIATE $$ SELECT 1; SELECT 2; $$").length
    assert_equal 2, Frostlake::Connection.statements("SELECT 1 -- a; b\n; SELECT 2").length
    assert_equal 1, Frostlake::Connection.statements("SELECT 1 /* a; b */").length
    assert_empty Frostlake::Connection.statements(" ; ")
  end

  def test_leading_words_skip_comments_and_fold_case
    assert_equal ["CREATE", "OR", "REPLACE"],
                 Frostlake::Connection.leading_words("/* c */ -- x\n create or replace table t", 3)
  end

  def test_which_statements_leave_session_state_behind
    {
      "USE SCHEMA s" => true, "use database d" => true, "SET x = 1" => true, "UNSET x" => true,
      "ALTER SESSION SET TIMEZONE = 'UTC'" => true, "CREATE OR REPLACE DATABASE d" => true,
      "CREATE SCHEMA IF NOT EXISTS s" => true, "DROP DATABASE d" => true,
      "CREATE TEMPORARY TABLE t (a INT)" => true, "CREATE OR REPLACE TEMP TABLE t (a INT)" => true,
      "CREATE LOCAL TEMPORARY TABLE t (a INT)" => true, "CREATE TABLE t (a INT)" => false,
      "CREATE OR REPLACE TRANSIENT TABLE t (a INT)" => false, "ALTER TABLE t ADD COLUMN b INT" => false,
      "SELECT 1" => false, "INSERT INTO t VALUES (1)" => false, "SELECT 'USE DATABASE x'" => false
    }.each do |sql, expected|
      assert_equal expected, Frostlake::Connection.touches_session?(sql), sql
    end
  end

  def test_transaction_control_is_recognised_and_a_scripting_block_is_not
    {
      "BEGIN" => :begins, "begin transaction" => :begins, "BEGIN WORK" => :begins,
      "BEGIN NAME t1" => :begins, "START TRANSACTION" => :begins, "COMMIT" => :ends,
      "ROLLBACK WORK" => :ends, "BEGIN LET x := 1; RETURN x; END" => nil, "SELECT 1" => nil
    }.each do |sql, expected|
      effect = Frostlake::Connection.transaction_effect(Frostlake::Connection.statements(sql).first)
      if expected.nil?
        assert_nil effect, sql
      else
        assert_equal expected, effect, sql
      end
    end
  end
end

class DriverTest < Minitest::Test
  include LocalZone

  def open_or_skip(database)
    skip "FROSTLAKE_CLASSPATH not set" if SERVER_DSN.nil?
    conn = Frostlake.connect(SERVER_DSN)
    conn.execute("CREATE OR REPLACE DATABASE #{database}")
    conn.execute("USE DATABASE #{database}")
    conn
  end

  def test_ddl_dml_and_typed_query
    conn = open_or_skip("rb_test_db")
    conn.execute("CREATE TABLE people (id INTEGER, name VARCHAR, score FLOAT, ok BOOLEAN)")
    inserted = conn.execute(
      "INSERT INTO people VALUES (?, ?, ?, ?), (?, ?, ?, ?)",
      [1, "Ada O'Hara \\ Byron", 9.5, true, 2, "Grace", 8.25, false]
    )
    assert_equal 2, inserted.row_count
    result = conn.execute("SELECT id, name, score, ok FROM people WHERE id = ?", [1])
    assert_equal [{ "ID" => 1, "NAME" => "Ada O'Hara \\ Byron", "SCORE" => 9.5, "OK" => true }],
                 result.rows
  ensure
    conn&.close
  end

  def test_text_and_binary_columns_report_their_declared_width
    conn = open_or_skip("rb_width_db")
    conn.execute("CREATE TABLE widths (s VARCHAR(9), b BINARY(5), n NUMBER(10,2), u VARCHAR)")
    columns = conn.execute("SELECT s, b, n, u FROM widths").columns
    # An engine that predates the field sends no width at all, and this driver
    # supports those: with nothing to report the checks below are skipped rather
    # than passed, so a green tick never claims a width the wire never carried.
    skip "this engine sends no column length" if columns[0][:length].nil?
    # Characters for the text column, bytes for the binary one.
    assert_equal 9, columns[0][:length]
    assert_equal 5, columns[1][:length]
    # Every other type carries no width at all: nil, never 0.
    assert_nil columns[2][:length]
    # Declared without a width, a text column still reports the maximum.
    assert_equal 16_777_216, columns[3][:length]
  ensure
    conn&.close
  end

  def test_session_state_persists
    conn = open_or_skip("rb_sess_db")
    conn.execute("CREATE TABLE t1 (a INTEGER)")
    conn.execute("INSERT INTO t1 VALUES (7)")
    assert_equal [{ "A" => 7 }], conn.execute("SELECT a FROM t1").rows
  ensure
    conn&.close
  end

  def test_transaction_block_rolls_back_on_error
    conn = open_or_skip("rb_tx_db")
    conn.execute("CREATE TABLE acc (n INTEGER)")
    conn.execute("INSERT INTO acc VALUES (1)")
    assert_raises(RuntimeError) do
      conn.transaction do
        conn.execute("INSERT INTO acc VALUES (2)")
        raise "boom"
      end
    end
    assert_equal [{ "N" => 1 }], conn.execute("SELECT COUNT(*) AS n FROM acc").rows
  ensure
    conn&.close
  end

  def test_temporal_round_trip
    conn = open_or_skip("rb_ts_db")
    # A bound Time is a TIMESTAMP_TZ, which a TIMESTAMP_TZ column keeps as it is:
    # the instant and the offset it was written with.
    conn.execute("CREATE TABLE stamps (id INTEGER, moment TIMESTAMP_TZ, d DATE)")
    moment = Time.new(2026, 8, 13, 12, 34, 56.789)
    conn.execute("INSERT INTO stamps VALUES (?, ?, ?)", [1, moment, Date.new(2026, 8, 13)])
    row = conn.execute("SELECT moment, d FROM stamps WHERE id = 1").rows.first
    assert_instance_of Time, row["MOMENT"]
    assert_in_delta moment.to_f, row["MOMENT"].to_f, 0.001
    assert_equal moment.utc_offset, row["MOMENT"].utc_offset
    assert_equal Date.new(2026, 8, 13), row["D"]
  ensure
    conn&.close
  end

  def test_a_bound_time_reaches_an_ntz_column_through_a_cast
    conn = open_or_skip("rb_ts_ntz_db")
    conn.execute("CREATE TABLE naive (id INTEGER, moment TIMESTAMP_NTZ)")
    moment = Time.new(2026, 8, 13, 12, 34, 56.789)
    # The account refuses a TIMESTAMP_TZ written into a TIMESTAMP_NTZ column while
    # compiling, so a bare bound Time is refused there too.
    error = assert_raises(Frostlake::QueryError) do
      conn.execute("INSERT INTO naive VALUES (?, ?)", [1, moment])
    end
    assert_match(/expecting TIMESTAMP_NTZ\(9\) but got TIMESTAMP_TZ\(9\)/, error.message)
    # Cast, it keeps the wall clock the Time was written with.
    conn.execute("INSERT INTO naive VALUES (?, CAST(? AS TIMESTAMP_NTZ))", [1, moment])
    stored = conn.execute("SELECT moment FROM naive WHERE id = 1").rows.first["MOMENT"]
    assert_equal moment.strftime("%F %T.%L"), stored.strftime("%F %T.%L")
  ensure
    conn&.close
  end

  def test_an_ntz_value_the_local_zone_skips_reads_and_writes_back_unchanged
    conn = open_or_skip("rb_ts_gap_db")
    conn.execute("CREATE TABLE naive (id INTEGER, moment TIMESTAMP_NTZ)")
    conn.execute("INSERT INTO naive VALUES (1, '2024-03-31 01:30:00')")
    # London skips 01:00-02:00 that night, and a host there still reads 01:30.
    in_local_zone("Europe/London") do
      read = conn.execute("SELECT moment FROM naive WHERE id = 1").rows.first["MOMENT"]
      assert_equal "2024-03-31 01:30:00", read.strftime("%F %T")
      # Written back through the cast a bound Time needs, it stores what it read.
      conn.execute("INSERT INTO naive VALUES (2, CAST(? AS TIMESTAMP_NTZ))", [read])
    end
    assert_equal [["2024-03-31 01:30:00.000"], ["2024-03-31 01:30:00.000"]],
                 conn.execute("SELECT moment::VARCHAR AS m FROM naive ORDER BY id").values
  ensure
    conn&.close
  end

  def test_error_surface_carries_the_engine_message
    conn = open_or_skip("rb_err_db")
    error = assert_raises(Frostlake::Error) { conn.execute("SELECT FROM nowhere") }
    assert_includes error.message, "SQL compilation error"
  ensure
    conn&.close
  end

  def test_update_and_merge_report_rows_affected
    conn = open_or_skip("rb_dml_db")
    conn.execute("CREATE TABLE t (id INTEGER, v INTEGER)")
    assert_equal 3, conn.execute("INSERT INTO t VALUES (1, 1), (2, 2), (3, 3)").row_count
    updated = conn.execute("UPDATE t SET v = v + 10 WHERE id <= 2")
    assert_equal 2, updated.row_count
    assert_empty updated.rows
    assert_equal 1, conn.execute("DELETE FROM t WHERE id = 3").row_count
    conn.execute("CREATE TABLE src (id INTEGER, v INTEGER)")
    conn.execute("INSERT INTO src VALUES (1, 100), (9, 900)")
    merged = conn.execute(
      "MERGE INTO t USING src ON t.id = src.id " \
      "WHEN MATCHED THEN UPDATE SET t.v = src.v " \
      "WHEN NOT MATCHED THEN INSERT VALUES (src.id, src.v)"
    )
    assert_equal 2, merged.row_count
  ensure
    conn&.close
  end

  def test_transaction_reraises_the_callers_error_when_the_rollback_fails
    conn = open_or_skip("rb_mask_db")
    error = assert_raises(RuntimeError) do
      conn.transaction do
        conn.close # the rollback that follows cannot succeed
        raise "user error"
      end
    end
    assert_equal "user error", error.message
  ensure
    conn&.close
  end

  def test_zoned_time_keeps_its_offset
    conn = open_or_skip("rb_tz_db")
    # An engine older than 0.1.0 answers +00:00 for a TIMESTAMP_TZ column, and
    # no client can recover the zone it dropped.
    engine = conn.execute("SELECT CURRENT_VERSION() AS v").rows.first["V"].to_s.split("-").first
    if Gem::Version.new(engine) < Gem::Version.new("0.1.0")
      skip "engine #{engine} predates TIMESTAMP_TZ offset support"
    end
    conn.execute("CREATE TABLE zoned (id INTEGER, moment TIMESTAMP_TZ)")
    moment = Time.new(2026, 1, 2, 3, 4, 5, "+05:00")
    conn.execute("INSERT INTO zoned VALUES (?, ?)", [1, moment])
    stored = conn.execute("SELECT moment FROM zoned WHERE id = 1").rows.first["MOMENT"]
    assert_equal moment.to_i, stored.to_i
    assert_equal moment.utc_offset, stored.utc_offset
  ensure
    conn&.close
  end

  def test_fixed_point_columns_survive_the_round_trip
    skip "bigdecimal is not available" unless defined?(BigDecimal)

    conn = open_or_skip("rb_num_db")
    conn.execute("CREATE TABLE n (d NUMBER(38,10), f FLOAT, i NUMBER(38,0), big NUMBER(38,0))")
    conn.execute("INSERT INTO n VALUES (0.1234567891, 1.5, 42, 12345678901234567890123456789012345678)")
    row = conn.execute("SELECT d, f, i, big FROM n").rows.first
    assert_equal "0.1234567891", row["D"].to_s("F")
    assert_instance_of Float, row["F"]
    assert_equal 42, row["I"]
    assert_equal 12_345_678_901_234_567_890_123_456_789_012_345_678, row["BIG"]
  ensure
    conn&.close
  end

  def test_execute_all_returns_every_result_set
    conn = open_or_skip("rb_multi_db")
    # A pack has to be asked for: a session takes one statement per request until it says otherwise.
    conn.execute("ALTER SESSION SET MULTI_STATEMENT_COUNT = 0")
    sets = conn.execute_all("SELECT 1 AS a; SELECT 2 AS b; SELECT 3 AS c;")
    assert_equal 3, sets.length
    assert_equal [[{ "A" => 1 }], [{ "B" => 2 }], [{ "C" => 3 }]], sets.map(&:rows)
    # execute keeps its old meaning: the first set.
    assert_equal [{ "A" => 1 }], conn.execute("SELECT 1 AS a; SELECT 2 AS b;").rows
  ensure
    conn&.close
  end

  def test_a_pack_can_declare_its_own_count_without_asking_the_session
    conn = open_or_skip("rb_per_call_db")
    # No ALTER SESSION anywhere: the count rides on the call that needs it.
    sets = conn.execute_all("SELECT 1 AS a; SELECT 2 AS b", [], multi_statement_count: 2)
    assert_equal [[{ "A" => 1 }], [{ "B" => 2 }]], sets.map(&:rows)
    # 0 means any number.
    any = conn.execute_all("SELECT 1 AS a; SELECT 2 AS b; SELECT 3 AS c", [],
                           multi_statement_count: 0)
    assert_equal 3, any.length
    # Only an engine carrying the statement-count gate refuses a pack at all, and
    # this driver supports older ones. Against one of those no refusal ever comes,
    # so the checks below are skipped rather than passed: a green tick would claim
    # an engine had been checked for a refusal it does not make.
    gated = begin
      conn.execute_all("SELECT 1 AS a; SELECT 2 AS b")
      false
    rescue Frostlake::QueryError
      true
    end
    unless gated
      skip "this engine accepts a pack nobody asked for, so it has no refusal to assert"
    end
    # A count the call does not hold is refused, in either direction.
    assert_raises(Frostlake::QueryError) { conn.execute("SELECT 1", [], multi_statement_count: 2) }
    # The session's own count is untouched by all of that, so a pack that
    # declares nothing still fails on a session that never asked for one.
    assert_raises(Frostlake::QueryError) { conn.execute_all("SELECT 1 AS a; SELECT 2 AS b") }
  ensure
    conn&.close
  end

  def test_a_closed_connection_says_so
    conn = open_or_skip("rb_closed_db")
    refute_predicate conn, :closed?
    conn.close
    assert_predicate conn, :closed?
    assert_raises(Frostlake::UsageError) { conn.ping }
    assert_raises(Frostlake::UsageError) { conn.execute("SELECT 1") }
    conn.close # closing twice is not an error
  end

  def test_one_connection_can_be_shared_between_threads
    conn = open_or_skip("rb_threads_db")
    collected = Queue.new
    threads = (1..4).map do |n|
      Thread.new do
        5.times { collected << conn.execute("SELECT #{n} AS v").rows.first["V"] }
      end
    end
    threads.each(&:join)
    assert_equal 20, collected.size
  ensure
    conn&.close
  end

  def test_duplicate_column_names_keep_every_value
    conn = open_or_skip("rb_dup_db")
    conn.execute("CREATE TABLE emp (id INTEGER, name VARCHAR, manager_id INTEGER)")
    conn.execute("INSERT INTO emp VALUES (1, 'Ada', NULL), (2, 'Grace', 1)")
    result = conn.execute(
      "SELECT e.id, e.name, m.id, m.name FROM emp e JOIN emp m ON e.manager_id = m.id"
    )
    assert_equal %w[ID NAME ID NAME], result.columns.map { |c| c[:name] }
    # A hash keyed by column name can only hold one ID and one NAME...
    assert_equal({ "ID" => 1, "NAME" => "Ada" }, result.rows.first)
    # ...so the positional view is the one that keeps the employee as well as
    # the manager.
    assert_equal [2, "Grace", 1, "Ada"], result.values.first
  ensure
    conn&.close
  end

  def test_values_lines_up_with_columns_for_ordinary_rows
    conn = open_or_skip("rb_values_db")
    conn.execute("CREATE TABLE t (a INTEGER, b VARCHAR)")
    conn.execute("INSERT INTO t VALUES (1, 'x'), (2, 'y')")
    result = conn.execute("SELECT a, b FROM t ORDER BY a")
    assert_equal [[1, "x"], [2, "y"]], result.values
    assert_equal [{ "A" => 1, "B" => "x" }, { "A" => 2, "B" => "y" }], result.rows
    # DML carries no columns, so it carries no positional values either.
    assert_empty conn.execute("INSERT INTO t VALUES (3, 'z')").values
  ensure
    conn&.close
  end

  def test_database_and_schema_come_from_the_dsn
    skip "FROSTLAKE_CLASSPATH not set" if SERVER_DSN.nil?
    setup = Frostlake.connect(SERVER_DSN)
    setup.execute("CREATE OR REPLACE DATABASE rb_dsn_db")
    setup.execute("CREATE SCHEMA IF NOT EXISTS rb_dsn_db.my_schema")
    setup.close

    conn = Frostlake.connect("#{SERVER_DSN}/rb_dsn_db?schema=my_schema")
    assert_equal [{ "D" => "RB_DSN_DB", "S" => "MY_SCHEMA" }],
                 conn.execute("SELECT CURRENT_DATABASE() AS d, CURRENT_SCHEMA() AS s").rows
  ensure
    conn&.close
  end

  def test_pending_use_still_applies_when_threads_share_the_connection
    skip "FROSTLAKE_CLASSPATH not set" if SERVER_DSN.nil?
    setup = Frostlake.connect(SERVER_DSN)
    setup.execute("CREATE OR REPLACE DATABASE rb_race_db")
    setup.close

    conn = Frostlake.connect("#{SERVER_DSN}/rb_race_db")
    seen = Queue.new
    threads = 8.times.map do
      Thread.new { seen << conn.execute("SELECT CURRENT_DATABASE() AS d").rows.first["D"] }
    end
    threads.each(&:join)
    databases = []
    databases << seen.pop until seen.empty?
    assert_equal ["RB_RACE_DB"], databases.uniq
  ensure
    conn&.close
  end

  def test_explicit_transaction_control
    conn = open_or_skip("rb_manual_tx_db")
    conn.execute("CREATE TABLE acc (n INTEGER)")
    conn.begin_transaction
    conn.execute("INSERT INTO acc VALUES (1)")
    conn.commit
    conn.begin_transaction
    conn.execute("INSERT INTO acc VALUES (2)")
    conn.rollback
    assert_equal [{ "N" => 1 }], conn.execute("SELECT n FROM acc ORDER BY n").rows
  ensure
    conn&.close
  end

  def test_result_is_enumerable
    conn = open_or_skip("rb_enum_db")
    conn.execute("CREATE TABLE t (a INTEGER)")
    conn.execute("INSERT INTO t VALUES (1), (2), (3)")
    result = conn.execute("SELECT a FROM t ORDER BY a")
    assert_equal [1, 2, 3], result.map { |row| row["A"] }
    assert_equal 3, result.count
    assert_equal({ "A" => 1 }, result.first)
  ensure
    conn&.close
  end

  def test_a_missing_database_in_the_dsn_fails_at_connect
    skip "FROSTLAKE_CLASSPATH not set" if SERVER_DSN.nil?
    # Not at whatever query happens to run first.
    error = assert_raises(Frostlake::QueryError) do
      Frostlake.connect("#{SERVER_DSN}/rb_no_such_db_at_all")
    end
    assert_match(/does not exist/i, error.message)
  end

  def test_a_failing_statement_stops_the_batch_and_keeps_what_ran
    conn = open_or_skip("rb_batch_db")
    # A pack has to be asked for, or the batch is refused before any of it runs.
    conn.execute("ALTER SESSION SET MULTI_STATEMENT_COUNT = 0")
    conn.execute("CREATE TABLE t (n INTEGER)")
    assert_raises(Frostlake::QueryError) do
      conn.execute_all("INSERT INTO t VALUES (1); SELECT 1/0 AS boom; INSERT INTO t VALUES (2);")
    end
    # No result sets come back for the statements that did run. As on the
    # account, each statement committed as it completed and execution stopped at
    # the failure: the INSERT before it stays, the one after it never ran.
    assert_equal [{ "N" => 1 }], conn.execute("SELECT COUNT(*) AS n FROM t").rows
  ensure
    conn&.close
  end

  def test_use_dsn_defaults_is_idempotent
    skip "FROSTLAKE_CLASSPATH not set" if SERVER_DSN.nil?
    setup = Frostlake.connect(SERVER_DSN)
    setup.execute("CREATE OR REPLACE DATABASE rb_idem_db")
    setup.close

    conn = Frostlake::Connection.new("#{SERVER_DSN}/rb_idem_db")
    conn.use_dsn_defaults
    conn.use_dsn_defaults # nothing pending now, so this is a no-op
    assert_equal [{ "D" => "RB_IDEM_DB" }],
                 conn.execute("SELECT CURRENT_DATABASE() AS d").rows
  ensure
    conn&.close
  end

  # An engine that predates newSession reaps an idle session and builds a fresh
  # one for the id we keep sending, which loses the database we selected and
  # says nothing about it. Standing in for that here: an engine that does not
  # track sessions, a move off the DSN's database, the caller's request for it
  # forgotten, and a long gap.
  def replaced_session(dsn_suffix = "")
    conn = Frostlake.connect("#{SERVER_DSN}/rb_idle_a#{dsn_suffix}")
    conn.execute("USE DATABASE rb_idle_b")
    conn.instance_variable_set(:@tracks_sessions, false)
    conn.instance_variable_set(:@session_touched, false)
    conn.instance_variable_set(:@last_used_at, -100_000)
    conn
  end

  def prepare_idle_databases
    setup = Frostlake.connect(SERVER_DSN)
    setup.execute("CREATE OR REPLACE DATABASE rb_idle_a")
    setup.execute("CREATE OR REPLACE DATABASE rb_idle_b")
    setup.close
  end

  def test_a_session_replaced_under_us_gets_its_database_back
    skip "FROSTLAKE_CLASSPATH not set" if SERVER_DSN.nil?
    prepare_idle_databases
    conn = replaced_session
    assert_equal [{ "D" => "RB_IDLE_A" }],
                 conn.execute("SELECT CURRENT_DATABASE() AS d").rows
  ensure
    conn&.close
  end

  def test_a_database_the_caller_selected_is_left_alone
    skip "FROSTLAKE_CLASSPATH not set" if SERVER_DSN.nil?
    prepare_idle_databases
    conn = Frostlake.connect("#{SERVER_DSN}/rb_idle_a")
    conn.execute("USE DATABASE rb_idle_b") # their choice, not a replaced session
    conn.instance_variable_set(:@tracks_sessions, false)
    conn.instance_variable_set(:@last_used_at, -100_000)
    assert_equal [{ "D" => "RB_IDLE_B" }],
                 conn.execute("SELECT CURRENT_DATABASE() AS d").rows
  ensure
    conn&.close
  end

  def test_the_idle_check_can_be_switched_off
    skip "FROSTLAKE_CLASSPATH not set" if SERVER_DSN.nil?
    prepare_idle_databases
    conn = replaced_session("?session_idle_limit=0")
    assert_equal [{ "D" => "RB_IDLE_B" }],
                 conn.execute("SELECT CURRENT_DATABASE() AS d").rows
  ensure
    conn&.close
  end

  def test_ping_succeeds_against_a_live_server
    conn = open_or_skip("rb_ping_db")
    assert_nil conn.ping
  ensure
    conn&.close
  end

  def test_each_result_set_carries_its_own_row_count
    conn = open_or_skip("rb_counts_db")
    # A pack has to be asked for: a session takes one statement per request until it says otherwise.
    conn.execute("ALTER SESSION SET MULTI_STATEMENT_COUNT = 0")
    conn.execute("CREATE TABLE t (n INTEGER)")
    sets = conn.execute_all("SELECT 1 AS a UNION ALL SELECT 2; INSERT INTO t VALUES (9);")
    assert_equal 2, sets.length
    assert_equal 2, sets[0].row_count
    # The second set is DML, so its count is rows affected rather than returned.
    assert_equal 1, sets[1].row_count
    assert_empty sets[1].values
  ensure
    conn&.close
  end

  def test_connect_closes_the_connection_when_the_dsn_database_is_missing
    skip "FROSTLAKE_CLASSPATH not set" if SERVER_DSN.nil?
    # No mocking library here, so stand in for Connection.new just long enough
    # to keep hold of the instance connect builds and then throws away.
    built = nil
    original = Frostlake::Connection.method(:new)
    Frostlake::Connection.define_singleton_method(:new) do |*args, **kwargs|
      built = original.call(*args, **kwargs)
    end
    begin
      assert_raises(Frostlake::QueryError) do
        Frostlake.connect("#{SERVER_DSN}/rb_definitely_missing_db")
      end
      assert_predicate built, :closed?
    ensure
      Frostlake::Connection.singleton_class.send(:remove_method, :new)
    end
  end
end

# A session the engine let go of, against a real engine: released behind the
# connection's back, the way the engine's idle expiry or a restart loses it.
class SessionLifetimeTest < Minitest::Test
  def setup
    skip "FROSTLAKE_CLASSPATH not set" if SERVER_DSN.nil?
  end

  def test_a_released_session_is_replaced_on_the_dsn_scope
    on_database("rb_lost_db") do |conn|
      lost = session_of(conn)
      assert_equal "200", release(lost).code
      assert_equal [{ "D" => "RB_LOST_DB" }], conn.execute("SELECT CURRENT_DATABASE() AS d").rows
      refute_equal lost, session_of(conn)
    end
  end

  def test_a_released_session_with_a_transaction_open_raises_session_lost
    on_database("rb_lost_tx_db") do |conn|
      conn.execute("CREATE TABLE t (n INTEGER)")
      conn.begin_transaction
      conn.execute("INSERT INTO t VALUES (1)")
      release(session_of(conn))
      error = assert_raises(Frostlake::SessionLostError) { conn.execute("INSERT INTO t VALUES (2)") }
      assert_match(/transaction/, error.message)
      # The release rolled the first INSERT back and the second never ran; the
      # connection carries on in a fresh session on the DSN's scope.
      assert_equal [{ "D" => "RB_LOST_TX_DB", "N" => 0 }],
                   conn.execute("SELECT CURRENT_DATABASE() AS d, COUNT(*) AS n FROM t").rows
    end
  end

  def test_a_released_session_whose_context_moved_raises_session_lost
    on_database("rb_lost_use_db") do |conn|
      conn.execute("CREATE SCHEMA elsewhere")
      conn.execute("USE SCHEMA PUBLIC")
      release(session_of(conn))
      error = assert_raises(Frostlake::SessionLostError) { conn.execute("SELECT 1") }
      assert_match(/context/, error.message)
      assert_equal [{ "D" => "RB_LOST_USE_DB" }], conn.execute("SELECT CURRENT_DATABASE() AS d").rows
    end
  end

  def test_closing_releases_the_session
    conn = Frostlake.connect(SERVER_DSN)
    conn.execute("SELECT 1")
    before = active_sessions
    conn.close
    assert_equal before - 1, active_sessions
  ensure
    conn&.close
  end

  # A begin that failed opened no transaction, so the INSERT after it is
  # committed: another session sees it.
  def test_writes_after_a_failed_begin_are_committed
    on_database("rb_failed_begin_db") do |conn|
      conn.execute("CREATE TABLE t (n INTEGER)")
      conn.execute("USE SCHEMA PUBLIC")
      release(session_of(conn))
      assert_raises(Frostlake::SessionLostError) { conn.begin_transaction }
      conn.execute("INSERT INTO t VALUES (1)")
      other = Frostlake.connect("#{SERVER_DSN}/rb_failed_begin_db")
      assert_equal [{ "N" => 1 }], other.execute("SELECT COUNT(*) AS n FROM t").rows
    ensure
      other&.close
    end
  end

  # Here BEGIN is never sent: the DSN's database does not exist yet, so the USE
  # queued ahead of it is refused.
  def test_writes_after_a_begin_behind_a_refused_use_are_committed
    admin = Frostlake.connect(SERVER_DSN)
    admin.execute("DROP DATABASE IF EXISTS rb_late_db")
    conn = Frostlake::Connection.new("#{SERVER_DSN}/rb_late_db")
    assert_raises(Frostlake::QueryError) { conn.begin_transaction }
    admin.execute("CREATE DATABASE rb_late_db")
    admin.execute("CREATE TABLE rb_late_db.public.t (n INTEGER)")
    # The queued USE goes through now, and the INSERT behind it commits.
    conn.execute("INSERT INTO t VALUES (1)")
    assert_equal [{ "N" => 1 }], admin.execute("SELECT COUNT(*) AS n FROM rb_late_db.public.t").rows
  ensure
    conn&.close
    admin&.close
  end

  private

  def on_database(name)
    setup = Frostlake.connect(SERVER_DSN)
    setup.execute("CREATE OR REPLACE DATABASE #{name}")
    setup.close
    conn = Frostlake.connect("#{SERVER_DSN}/#{name}")
    yield conn
  ensure
    conn&.close
  end

  def session_of(conn)
    conn.instance_variable_get(:@session_id)
  end

  def endpoint
    URI(SERVER_DSN.sub("frostlake://", "http://"))
  end

  def release(session_id)
    Net::HTTP.start(endpoint.host, endpoint.port) do |http|
      http.request(Net::HTTP::Delete.new("/api/sessions/#{session_id}"))
    end
  end

  def active_sessions
    JSON.parse(Net::HTTP.get(endpoint.host, "/api/sessions", endpoint.port))["activeSessions"]
  end
end

# The engine's testkit corpus through this driver: testkit_runner.rb, run when
# FL_CORPUS names the testkit directory, against FROSTLAKE_URL or an engine it
# boots from FROSTLAKE_CLASSPATH.
class TestkitCorpusTest < Minitest::Test
  def test_the_corpus_replays_through_the_driver
    corpus = ENV.fetch("FL_CORPUS", "")
    skip FrostlakeTestkit::NO_CORPUS if corpus.strip.empty?
    refute_empty FrostlakeTestkit.suite_files(corpus), "FL_CORPUS=#{corpus} holds no suites/*.json"
    if ENV.fetch("FROSTLAKE_URL", "").strip.empty? && ENV.fetch("FROSTLAKE_CLASSPATH", "").strip.empty?
      skip "no engine; set FROSTLAKE_URL, or FROSTLAKE_CLASSPATH to boot one"
    end

    assert_equal 0, FrostlakeTestkit.main, "a corpus case failed or errored; the replay's report lists them"
  end
end
