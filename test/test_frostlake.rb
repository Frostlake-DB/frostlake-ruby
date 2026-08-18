# frozen_string_literal: true

require "minitest/autorun"
require "net/http"
require "socket"

require_relative "../lib/frostlake"

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
    assert_equal ['USE DATABASE "db"'], trailing.instance_variable_get(:@pending_use)
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

class ConversionTest < Minitest::Test
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

class DriverTest < Minitest::Test
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
    conn.execute("CREATE TABLE stamps (id INTEGER, moment TIMESTAMP_NTZ, d DATE)")
    moment = Time.new(2026, 8, 13, 12, 34, 56.789)
    conn.execute("INSERT INTO stamps VALUES (?, ?, ?)", [1, moment, Date.new(2026, 8, 13)])
    row = conn.execute("SELECT moment, d FROM stamps WHERE id = 1").rows.first
    assert_instance_of Time, row["MOMENT"]
    assert_in_delta moment.to_f, row["MOMENT"].to_f, 0.001
    assert_equal Date.new(2026, 8, 13), row["D"]
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
    sets = conn.execute_all("SELECT 1 AS a; SELECT 2 AS b; SELECT 3 AS c;")
    assert_equal 3, sets.length
    assert_equal [[{ "A" => 1 }], [{ "B" => 2 }], [{ "C" => 3 }]], sets.map(&:rows)
    # execute keeps its old meaning: the first set.
    assert_equal [{ "A" => 1 }], conn.execute("SELECT 1 AS a; SELECT 2 AS b;").rows
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

  def test_a_failing_statement_discards_the_whole_batch
    conn = open_or_skip("rb_batch_db")
    conn.execute("CREATE TABLE t (n INTEGER)")
    assert_raises(Frostlake::QueryError) do
      conn.execute_all("INSERT INTO t VALUES (1); SELECT 1/0 AS boom;")
    end
    # No result sets come back for the statements that did run, and the INSERT
    # before the failure leaves nothing behind either.
    assert_equal [{ "N" => 0 }], conn.execute("SELECT COUNT(*) AS n FROM t").rows
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

  # The engine reaps an idle session and builds a fresh one for the id we keep
  # sending, which loses the database we selected and says nothing about it.
  # Standing in for that here: move off the DSN's database, forget that the
  # caller asked for it, and claim a long gap.
  def replaced_session(dsn_suffix = "")
    conn = Frostlake.connect("#{SERVER_DSN}/rb_idle_a#{dsn_suffix}")
    conn.execute("USE DATABASE rb_idle_b")
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
