# frozen_string_literal: true

# Replays the engine's testkit corpus through this driver.
#
# The corpus belongs to the engine: language-neutral JSON suites under
# frostlake/engine/src/test/resources/testkit/suites, their format in the
# SCHEMA.md beside them. Every statement travels Frostlake.connect ->
# Connection#execute -> POST /api/execute, and every cell is compared as this
# driver hands it back, so a case checks the driver's decoding as well as the
# engine's answer. The rules are the engine's reference runner's (JsonSuiteTest,
# Compare and HttpBackend in engine/src/test/java/dev/frostlake/testkit), and
# suites added on the engine side are picked up with no change here.
#
#   FL_CORPUS=/path/to/frostlake/engine/src/test/resources/testkit \
#     FROSTLAKE_URL=frostlake://127.0.0.1:18082 ruby testkit_runner.rb
#
#   FL_CORPUS                 the testkit directory, whose suites/*.json are
#                             replayed; without it the run is skipped
#   FROSTLAKE_URL             the running engine to replay against; without it,
#                             FROSTLAKE_CLASSPATH boots one for the run
#   FROSTLAKE_TESTKIT_REPORT  the TSV report, one row per case (default:
#                             results/testkit-ruby.tsv); missing-apis-ruby.md
#                             is written beside it
#   FROSTLAKE_TESTKIT_FILTER  comma-separated words: only the suites whose name
#                             contains one of them
#
# How a case runs:
#   - a case whose skip clause names `ruby`, or `http` (the transport this
#     driver rides), is reported SKIP;
#   - every other case gets a connection of its own, which is one session, and
#     resets it with the contract's five statements before its steps, so USE,
#     variables and transactions carry across its steps and no further;
#   - the first failed check stops the case (FAIL); a transport failure is an
#     ERROR, never an expected error;
#   - capabilities: SESSION, COLUMN_NAMES and UPDATE_COUNT. There is no
#     ERROR_CODE: the protocol carries a message only, so an expected error's
#     code or sqlState is recorded in missing-apis-ruby.md rather than failed.
#
# test/test_frostlake.rb runs it as one of its tests when FL_CORPUS is set.
#
# Exits 1 when a case failed or errored, or FL_CORPUS holds no suites, else 0.

require "fileutils"
require "json"
require "net/http"
require "socket"
require "tmpdir"

require_relative "lib/frostlake"

module FrostlakeTestkit
  BACKEND = "ruby"

  # A skip clause names backends. This driver speaks the HTTP transport, so a
  # case skipped for `http` is skipped here too.
  SKIPPED_FOR = [BACKEND, "http"].freeze

  # Why a run with no FL_CORPUS replays nothing.
  NO_CORPUS = "set FL_CORPUS to frostlake's engine/src/test/resources/testkit to replay the testkit corpus"

  # Before every case: a session that takes a script of any length, then a
  # fresh test_db.test_schema, made current.
  RESET = [
    "ALTER SESSION SET MULTI_STATEMENT_COUNT = 0",
    "CREATE OR REPLACE DATABASE test_db",
    "USE DATABASE test_db",
    "CREATE OR REPLACE SCHEMA test_schema",
    "USE SCHEMA test_schema"
  ].freeze

  SEMI_STRUCTURED = ["VARIANT", "OBJECT", "ARRAY"].freeze
  ZONED_TIMESTAMPS = ["TIMESTAMP_LTZ", "TIMESTAMP_TZ"].freeze

  CELL_SEPARATOR = "\u001f"

  # The number syntax Java's BigDecimal reads: a sign, digits with at most one
  # point (either side of it may be empty, not both), and an exponent.
  NUMBER = /\A([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?\z/.freeze

  # Past this many digits a plain rendering is not worth building: no real
  # value has one, and the text still compares as text.
  MAX_PLAIN_DIGITS = 10_000

  MISSING_ERROR_CODE = "ERROR_CODE: cannot check error code/sqlState (backend reports message only)"

  # As long as the reference waits for a statement; a DSN that sets its own
  # read_timeout keeps it.
  STATEMENT_TIMEOUT = 60

  # A report row's detail is one line, and a grid diff can be long.
  MAX_DETAIL = 2000
  MAX_LISTED_FAILURES = 25

  # One statement's outcome in the reference's shape: the first result set's
  # column names and its cells as text, the DML row count or -1, or the
  # refusal's message.
  Outcome = Struct.new(:columns, :rows, :update_count, :error)

  class << self
    def main
      corpus = ENV["FL_CORPUS"]
      if blank?(corpus)
        puts "testkit [#{BACKEND}]: #{NO_CORPUS}"
        return 0
      end
      files = suite_files(corpus)
      if files.empty?
        warn "testkit [#{BACKEND}]: FL_CORPUS=#{corpus} holds no suites/*.json"
        return 1
      end
      if blank?(ENV["FROSTLAKE_URL"]) && blank?(ENV["FROSTLAKE_CLASSPATH"])
        puts "testkit [#{BACKEND}]: no engine; set FROSTLAKE_URL, or FROSTLAKE_CLASSPATH to boot one"
        return 0
      end

      engine = nil
      begin
        dsn = ENV["FROSTLAKE_URL"]
        if blank?(dsn)
          engine = boot_engine(ENV["FROSTLAKE_CLASSPATH"])
          dsn = engine[:dsn]
        end
        replay(dsn, files)
      ensure
        stop_engine(engine) unless engine.nil?
      end
    end

    # The suite files of the testkit directory `corpus`, in name order.
    def suite_files(corpus)
      Dir.glob(File.join(corpus, "suites", "*.json")).sort
    end

    private

    def replay(dsn, files)
      words = (ENV["FROSTLAKE_TESTKIT_FILTER"] || "").split(",").map { |word| word.strip.downcase }
      words.reject!(&:empty?)
      counts = Hash.new(0)
      report = []
      missing = []
      started = monotonic_now
      files.each do |path|
        document = JSON.parse(File.read(path, encoding: "UTF-8"), **number_options)
        suite = (document["suite"] || File.basename(path, ".json")).to_s
        next unless words.empty? || words.any? { |word| suite.downcase.include?(word) }

        (document["tests"] || []).each do |test|
          name = test["name"].to_s
          skip_key = skipped_for(test["skip"])
          if skip_key
            counts["SKIP"] += 1
            report << [suite, name, "SKIP", "", "skip[#{skip_key}]: #{test['skip']['reason']}", 0]
            next
          end
          begin_at = monotonic_now
          status, step, detail = run_case(dsn, test, "#{suite} / #{name}", missing)
          counts[status] += 1
          report << [suite, name, status, step, detail, ((monotonic_now - begin_at) * 1000).round]
        end
      end

      report_path = ENV["FROSTLAKE_TESTKIT_REPORT"]
      report_path = File.join(__dir__, "results", "testkit-#{BACKEND}.tsv") if blank?(report_path)
      write_report(report_path, report)
      notes_path = File.join(File.dirname(report_path), "missing-apis-#{BACKEND}.md")
      write_missing_apis(notes_path, missing)

      failed = counts["FAIL"] + counts["ERROR"]
      # A runner error counts as a failure on this line; the report keeps them apart.
      puts "testkit [#{BACKEND}]: #{counts['PASS']} passed, #{failed} failed, #{counts['SKIP']} skipped"
      puts format("  %<fail>d FAIL, %<error>d ERROR, %<checks>d check(s) needing an API the " \
                  "HTTP transport lacks; %<files>d suite files in %<seconds>.1f s",
                  fail: counts["FAIL"], error: counts["ERROR"], checks: missing.length,
                  files: files.length, seconds: monotonic_now - started)
      puts "  report: #{report_path}"
      listed = report.select { |row| row[2] == "FAIL" || row[2] == "ERROR" }.first(MAX_LISTED_FAILURES)
      listed.each do |row|
        puts "  #{row[0]} / #{row[1]}: #{row[2]} step #{row[3]}: #{row[4][0, 300]}"
      end
      failed.zero? ? 0 : 1
    end

    # The backend a skip clause names that this runner answers to, or nil.
    def skipped_for(clause)
      return nil unless clause.is_a?(Hash) && clause["backends"].is_a?(Array)

      clause["backends"].each do |entry|
        SKIPPED_FOR.each do |name|
          return name if name.casecmp?(entry.to_s)
        end
      end
      nil
    end

    # Runs one case on a connection of its own: [status, failed step, detail].
    def run_case(dsn, test, where, missing)
      number = nil
      conn = connect(dsn)
      RESET.each do |sql|
        outcome = execute(conn, sql)
        raise "resetContext failed on '#{sql}': #{outcome.error}" if outcome.error
      end
      (test["steps"] || []).each_with_index do |step, index|
        number = index + 1
        sql = step["sql"].to_s
        detail, absent = check(step["expect"], execute(conn, sql))
        missing << [absent, "#{where} step #{number}"] if absent
        return ["FAIL", number, one_line("#{detail}  [sql: #{sql}]")] if detail
      end
      ["PASS", "", ""]
    rescue StandardError => e
      # Anything but a refusal is the transport or the runner: an ERROR.
      ["ERROR", number || "", one_line("#{e.class}: #{e.message}")]
    ensure
      conn&.close
    end

    def connect(dsn)
      query = URI(dsn).query
      given = !query.nil? && URI.decode_www_form(query).to_h.key?("read_timeout")
      Frostlake.connect(dsn, read_timeout: given ? nil : STATEMENT_TIMEOUT)
    end

    # One statement through the driver's public API. A refusal comes back in
    # the outcome; anything else raises.
    def execute(conn, sql)
      result = begin
        conn.execute(sql)
      rescue Frostlake::QueryError => e
        return Outcome.new([], [], -1, e.message)
      end
      if result.columns.empty?
        # The driver folds a DML status row ("number of rows inserted", ...)
        # into row_count and hands back no grid, so the count is what it
        # reports. A statement that answered no result set at all reads as 0.
        return Outcome.new([], [], result.row_count, nil)
      end

      names = result.columns.map { |column| column[:name] }
      rows = result.values.map do |cells|
        texts = []
        cells.each_with_index { |cell, i| texts << cell_text(cell, result.columns[i]) }
        texts
      end
      Outcome.new(names, rows, grid_update_count(names, rows), nil)
    end

    # The reference's derivation, for a count grid the driver did not fold: a
    # single row whose every column is a "number of ..." counter.
    def grid_update_count(names, rows)
      return -1 if names.empty? || rows.length != 1

      names.each do |name|
        return -1 if name.nil? || !name.downcase.start_with?("number of")
      end
      first = rows[0][0].to_s.strip
      first.match?(/\A[+-]?\d+\z/) ? first.to_i : -1
    end

    # -- cells ----------------------------------------------------------------

    # A driver cell as the text the wire carried for it, which is what the
    # reference compares: the driver's typed values are turned back into the
    # engine's spellings, and a semi-structured cell is then decoded once.
    def cell_text(cell, column)
      type = column[:data_type].to_s.upcase
      text = case cell
             when nil then nil
             when true, false then cell.to_s
             when Time then timestamp_text(cell, type)
             when Date then cell.strftime("%Y-%m-%d")
             when String
               # A BINARY cell the driver decoded crossed as upper-case hex.
               cell.encoding == Encoding::BINARY ? cell.unpack1("H*").upcase : cell
             else
               java_text(cell)
             end
      SEMI_STRUCTURED.include?(type) ? semi_structured_value(text) : text
    end

    # A number in plain digits, and a JSON object or array the wire carried as
    # a cell spelled the way the reference prints the Java collection it reads
    # one into: {key=value, ...} and [item, ...].
    def java_text(value)
      case value
      when nil then "null"
      when Hash then "{#{value.map { |key, item| "#{key}=#{java_text(item)}" }.join(', ')}}"
      when Array then "[#{value.map { |item| java_text(item) }.join(', ')}]"
      else defined?(BigDecimal) && value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s
      end
    end

    # A TIMESTAMP cell in the engine's transport text: the wall clock, three,
    # six or nine digits of fraction (as many as the value needs, at least
    # three), and the offset for the zoned types.
    def timestamp_text(time, type)
      text = time.strftime("%Y-%m-%d %H:%M:%S.") + fraction_text(time.nsec)
      ZONED_TIMESTAMPS.include?(type) ? "#{text} #{time.strftime('%z')}" : text
    end

    def fraction_text(nanos)
      nine = format("%09d", nanos)
      return nine[0, 3] if (nanos % 1_000_000).zero?
      return nine[0, 6] if (nanos % 1000).zero?

      nine
    end

    # A VARIANT, OBJECT or ARRAY cell reaches a client as its JSON text, a
    # string's own quotes included, while the suites record the value: a cell
    # that is one JSON string becomes that string's content, and anything else
    # (a number, an object, text that is not JSON) is left as it came.
    def semi_structured_value(text)
      return nil if text.nil?

      parsed = JSON.parse(text)
      parsed.is_a?(String) ? parsed : text
    rescue JSON::ParserError, EncodingError
      text
    end

    # -- checks (the reference's Compare) ---------------------------------------

    # [failure detail or nil, missing-API note or nil] for one step.
    def check(expect, outcome)
      expect = nil unless expect.is_a?(Hash)
      error = expect && expect["error"]
      return check_refusal(error, outcome) if error.is_a?(Hash)
      return ["unexpected error: #{outcome.error}", nil] if outcome.error
      return [nil, nil] if expect.nil?

      if expect.key?("value")
        want = expected_text(expect["value"])
        actual = first_cell(outcome.rows)
        if norm(want) != norm(actual)
          return ["value [#{actual.nil? ? 'null' : actual}] != expected [#{want.nil? ? 'null' : want}]", nil]
        end
      end
      if expect["rows"].is_a?(Array)
        diff = grid_diff(expect["rows"], outcome.rows, expect["ordered"] == true)
        return [diff, nil] if diff
      end
      if expect["rowCount"].is_a?(Numeric)
        want = expect["rowCount"].to_i
        return ["rowCount #{outcome.rows.length} != expected #{want}", nil] if outcome.rows.length != want
      end
      if expect["columns"].is_a?(Array)
        mismatch = column_mismatch(expect["columns"], outcome.columns)
        return [mismatch, nil] if mismatch
      end
      if expect["updateCount"].is_a?(Numeric)
        want = expect["updateCount"].to_i
        if outcome.update_count != want
          return ["updateCount #{outcome.update_count} != expected #{want}", nil]
        end
      end
      [nil, nil]
    end

    # The statement is expected to fail: it did, with the named message.
    def check_refusal(error, outcome)
      return ["expected an error, statement succeeded", nil] if outcome.error.nil?

      want = error["messageContains"]
      if !want.nil? && !outcome.error.downcase.include?(want.to_s.downcase)
        return ["error message [#{outcome.error}] does not contain [#{want}]", nil]
      end
      return [nil, nil] if error["code"].nil? && error["sqlState"].nil?

      [nil, MISSING_ERROR_CODE]
    end

    def first_cell(rows)
      return nil if rows.empty? || rows[0].empty?

      rows[0][0]
    end

    def column_mismatch(expected, actual)
      if actual.length != expected.length
        return "column count #{actual.length} != expected #{expected.length} [#{actual.join(', ')}]"
      end

      expected.each_with_index do |want, i|
        got = actual[i]
        want = want.nil? ? "null" : expected_text(want)
        return "column[#{i}] [#{got}] != expected [#{want}]" if got.nil? || !want.casecmp?(got)
      end
      nil
    end

    def grid_diff(want_rows, got_rows, ordered)
      want = want_rows.map { |row| canon(row.map { |cell| expected_text(cell) }) }
      got = got_rows.map { |row| canon(row) }
      unless ordered
        want = want.sort
        got = got.sort
      end
      return nil if want == got

      "rows differ: expected #{grid_text(want)} got #{grid_text(got)}"
    end

    def canon(cells)
      cells.map { |cell| norm(cell) + CELL_SEPARATOR }.join
    end

    def grid_text(rows)
      "[#{rows.map { |row| row.chomp(CELL_SEPARATOR).tr(CELL_SEPARATOR, '|') }.join(', ')}]"
    end

    # An expected value as text, the way the reference reads it: null stays
    # SQL NULL and a number keeps its written digits.
    def expected_text(value)
      value.nil? ? nil : java_text(value)
    end

    # The shared normalization, applied to both sides: NULL and the empty
    # string alike, booleans in any case, anything numeric rounded to 10
    # significant digits, everything else exact trimmed text.
    def norm(raw)
      return "NULL" if raw.nil?

      # Java's trim: every character up to U+0020 goes from both ends.
      value = raw.sub(/\A[\x00-\x20]+/, "").sub(/[\x00-\x20]+\z/, "")
      return "NULL" if value.empty? || value.casecmp?("null")
      return "TRUE" if value.casecmp?("true")
      return "FALSE" if value.casecmp?("false")

      plain_decimal(value) || value
    end

    # A number rounded HALF_UP to 10 significant digits and printed plain with
    # no trailing zeros, as the reference's BigDecimal prints it; nil when the
    # text is not a number. Integers keep it exact at any size.
    def plain_decimal(value)
      match = NUMBER.match(value)
      return nil if match.nil?

      sign, whole, fraction, exponent = match.captures
      fraction ||= ""
      return nil if whole.empty? && fraction.empty?

      digits = (whole + fraction).sub(/\A0+/, "")
      return "0" if digits.empty?

      # The value is digits x 10^scale.
      scale = exponent.to_i - fraction.length
      if digits.length > 10
        scale += digits.length - 10
        kept = digits[0, 10].to_i
        kept += 1 if digits[10] >= "5"
        digits = kept.to_s
      end
      stripped = digits.sub(/0+\z/, "")
      scale += digits.length - stripped.length
      digits = stripped
      return nil if scale.abs > MAX_PLAIN_DIGITS

      text = if scale >= 0
               digits + ("0" * scale)
             elsif -scale >= digits.length
               "0.#{'0' * (-scale - digits.length)}#{digits}"
             else
               "#{digits[0...(digits.length + scale)]}.#{digits[(digits.length + scale)..]}"
             end
      sign == "-" ? "-#{text}" : text
    end

    # -- files and the engine ---------------------------------------------------

    # Numbers in a suite keep their written digits when bigdecimal is there.
    def number_options
      defined?(BigDecimal) ? { decimal_class: BigDecimal } : {}
    end

    def write_report(path, rows)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "w", encoding: "UTF-8") do |out|
        out.write("suite\ttest\tstatus\tfailedStep\tdetail\tms\n")
        rows.each { |row| out.write("#{row.map { |cell| one_line(cell.to_s) }.join("\t")}\n") }
      end
    end

    # Checks the corpus asks for that this transport cannot express. They are
    # recorded rather than failed, and light up the day the protocol has them.
    def write_missing_apis(path, missing)
      FileUtils.mkdir_p(File.dirname(path))
      grouped = missing.group_by(&:first)
      File.open(path, "w", encoding: "UTF-8") do |out|
        out.write("# Missing APIs for backend `#{BACKEND}`\n\n")
        out.write("Checks the suites ask for that this driver's transport cannot express. " \
                  "They are not failures: the day the API exists they light up.\n\n")
        out.write("None.\n") if grouped.empty?
        grouped.each do |note, places|
          out.write("- #{note} (#{places.length} check#{places.length == 1 ? '' : 's'})\n")
          places.each { |(_, where)| out.write("  - #{where}\n") }
        end
      end
    end

    # Boots a DatabaseHttpServer from a classpath on a free port, in a private
    # user.home so its stage files and log go with the run.
    def boot_engine(classpath)
      java = blank?(ENV["JAVA_HOME"]) ? "java" : File.join(ENV["JAVA_HOME"], "bin", "java")
      probe = TCPServer.new("127.0.0.1", 0)
      port = probe.addr[1]
      probe.close
      home = Dir.mktmpdir("frostlake-testkit-")
      pid = Process.spawn(java, "-Duser.home=#{home}", "-cp", classpath,
                          "dev.frostlake.http.DatabaseHttpServer", port.to_s,
                          chdir: home, out: File::NULL, err: File::NULL)
      engine = { dsn: "frostlake://127.0.0.1:#{port}", pid: pid, home: home }
      150.times do
        begin
          health = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/api/health"))
          return engine if health.is_a?(Net::HTTPSuccess)
        rescue SystemCallError, IOError
          # not listening yet
        end
        if Process.wait(pid, Process::WNOHANG)
          engine[:pid] = nil
          raise "the engine exited during startup"
        end
        sleep 0.2
      end
      raise "the engine did not become healthy on port #{port}"
    rescue StandardError
      stop_engine(engine) unless engine.nil?
      raise
    end

    def stop_engine(engine)
      unless engine[:pid].nil?
        begin
          Process.kill("TERM", engine[:pid])
          Process.wait(engine[:pid])
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
      end
      FileUtils.remove_entry(engine[:home], true)
    end

    def one_line(text)
      line = text.gsub(/[\t\r\n]+/, " ")
      line.length > MAX_DETAIL ? "#{line[0, MAX_DETAIL]}..." : line
    end

    def blank?(text)
      text.nil? || text.strip.empty?
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

exit(FrostlakeTestkit.main) if $PROGRAM_NAME == __FILE__
