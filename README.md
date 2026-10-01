# frostlake-ruby

A zero-dependency Ruby driver for [Frostlake](https://frostlake.dev), speaking the
engine's HTTP protocol against a running `DatabaseHttpServer`. Ruby ≥ 3.0, stdlib only
(`net/http`, `json`, `uri`, `date`, `time`, and `bigdecimal` when it is available).

## Installation

```sh
gem install frostlake
```

Or in a Gemfile:

```ruby
gem "frostlake"
```

The database and schema named in the DSN are applied by `Frostlake.connect`, so a
name that does not exist is reported there rather than surfacing later on whatever
query happens to run first. They are quoted before they are sent, so a name that
could not appear unquoted — one starting with a digit, or a reserved word — is
passed through intact.

## Engine version

Requires a Frostlake engine **0.2.0 or newer**. Ask a running server which one it is with
`SELECT CURRENT_VERSION()` — every release answers it, so the check works against any engine.

The driver versions independently of the engine: it speaks the HTTP protocol, not
the jar, so this is a floor rather than a lockstep pin.

One behaviour does depend on the engine: a `TIMESTAMP_TZ` column only reports back the
UTC offset it was given from engine **0.1.0** on. Against an older engine a bound `Time`
still round-trips, but the offset comes back as `+00:00`. Recovering from a lost session
and releasing the session on close need **0.1.0** too; see [Session lifetime](#session-lifetime).

## Usage

```ruby
require "frostlake"

conn = Frostlake.connect("frostlake://localhost:18082/MY_DB?schema=PUBLIC")

conn.execute("CREATE TABLE people (id INTEGER, name VARCHAR)")
result = conn.execute("INSERT INTO people VALUES (?, ?), (?, ?)", [1, "Ada", 2, "Grace"])
result.row_count # => 2

result = conn.execute("SELECT id, name FROM people WHERE id = ?", [1])
result.rows # => [{ "ID" => 1, "NAME" => "Ada" }]

conn.close
```

`execute(sql, binds = [])` returns a `Frostlake::Result` with `columns`, `rows`
(hashes keyed by column name; the result is `Enumerable` over them), `values` and
`row_count` (the affected-row count for DML). A failed statement raises
`Frostlake::Error` carrying the engine's error message.

`values` is what the wire delivered: every cell, positionally, lined up with
`columns`. `rows` is a view over it keyed by column name, built the first time you
ask and then kept — so a caller that only reads `values` never pays for the hashes.
Because it is keyed by name it cannot hold two columns called the same thing: a
self-join reports `ID` twice and the later one wins, while `values` keeps both.

```ruby
result = conn.execute("SELECT e.id, e.name, m.id, m.name FROM emp e JOIN emp m ON e.manager_id = m.id")
result.columns.map { |c| c[:name] }  # => ["ID", "NAME", "ID", "NAME"]
result.rows.first                    # => {"ID" => 1, "NAME" => "Ada"}
result.values.first                  # => [2, "Grace", 1, "Ada"]
```

### Transactions

```ruby
conn.transaction do
  conn.execute("INSERT INTO acc VALUES (2)")
end                          # commits; rolls back if the block raises

conn.begin_transaction       # or drive it by hand
conn.execute("...")
conn.commit                  # / conn.rollback
```

`begin_transaction` sends `BEGIN` with autocommit off, and the connection leaves
autocommit only once the engine has opened the transaction. A begin that fails — refused,
unanswered or unreadable, lost with its session, or never sent because a `USE` queued
ahead of it was refused — leaves the connection in autocommit, so the statements after it
commit as they run. `transaction` follows a begin that fails with a best-effort rollback
as well, in case a `BEGIN` whose answer was lost did open a transaction.

### Bind values

Parameters are inlined client-side (`?` placeholders); placeholders inside string
literals, quoted identifiers, comments and `$$…$$` bodies are left alone. Too few
bind values raises `Frostlake::UsageError`; surplus ones are ignored, matching
Frostlake's other drivers.

| Ruby value | SQL literal |
| --- | --- |
| `nil` | `NULL` |
| `true` / `false` | `TRUE` / `FALSE` |
| `Integer` / `Float` / `BigDecimal` | as written |
| `String` (UTF-8) / `Symbol` | `'…'` (backslashes and quotes escaped) |
| `String` with `ASCII-8BIT` encoding | `X'hex'` (binary marker) |
| `Time` / `DateTime` | `'…±hh:mm'::TIMESTAMP_TZ` (a Ruby `Time` always carries an offset) |
| `Date` | `'…'::DATE` |
| `Array` | `[…]` (elements formatted recursively) |

A bound `Time` goes into a `TIMESTAMP_TZ` column as it is. A `TIMESTAMP_NTZ` or
`TIMESTAMP_LTZ` column refuses it while compiling, as the account refuses any
`TIMESTAMP_TZ` written into one (`expecting TIMESTAMP_NTZ(9) but got TIMESTAMP_TZ(9)`),
so cast the bind there: `CAST(? AS TIMESTAMP_NTZ)` keeps the wall clock the `Time` was
written with, and `CAST(? AS TIMESTAMP_LTZ)` keeps its instant.

### Result types

Fixed-point `NUMBER` keeps the exact digits the engine sent: `BigDecimal` when the
column has a scale, `Integer` when it does not (of any size — Ruby integers are
arbitrary precision). `FLOAT`/`DOUBLE`/`REAL` are genuine binary floats and stay
`Float`. `BOOLEAN` becomes `true`/`false`, `DATE` a `Date`, `TIMESTAMP*` a `Time`,
`BINARY` a binary-encoded `String`; `TIME` and semi-structured values keep their
wire shape as strings.

A `TIMESTAMP_NTZ` is a wall clock with no zone of its own, so it comes back as a `Time`
flagged UTC (`utc?` is true) whose fields read back exactly as stored, whatever zone the
host is in; a column declared `DATETIME`, or `TIMESTAMP` under the default mapping, is
one. Read in the host's local zone instead, a wall clock that zone skips would move:
`2024-03-31 01:30` does not exist in London, whose clocks go from 01:00 straight to 02:00
that night, so it would come back as `02:30 +0100`. The instant such a `Time` names is its
wall clock read as UTC, the one the engine's own epoch arithmetic
(`DATE_PART(EPOCH_SECOND, …)`) gives the value, and written back through
`CAST(? AS TIMESTAMP_NTZ)` it stores the wall clock it was read with. `TIMESTAMP_LTZ` and
`TIMESTAMP_TZ` carry an offset on the wire and come back as a `Time` at that instant and
offset.

Each entry in `columns` is a hash of `{ name:, data_type:, scale:, length: }`, carrying
the engine's own type name. `length` is the width a text or binary column was declared
with — characters for `VARCHAR(9)`, bytes for `BINARY(5)`, and the maximum (16777216 /
8388608) for one declared without a width. Every other type reports `nil`: the server
sends no width for it, and `nil` is that, not a width of `0`.

A result set arrives as one JSON body and is fully materialised — the driver holds
every row in memory, and the protocol offers no cursor to page through a large
`SELECT`. Bound the query rather than expecting the driver to stream it.

Exact decimals need `bigdecimal`, which ships with Ruby. If it cannot be loaded —
a bundler setup on Ruby ≥ 3.4 without it in the Gemfile — those cells fall back to
`Float` rather than the driver failing to load.

### Several statements at once

A request carries one statement unless the session asks for more, as on the account, so a pack
sent without asking is refused with `Actual statement count 2 did not match the desired
statement count 1.` Ask with `ALTER SESSION SET MULTI_STATEMENT_COUNT = n`, or `0` for any
number.

`execute` returns the first result set. `execute_all` returns every one, in order:

```ruby
conn.execute("ALTER SESSION SET MULTI_STATEMENT_COUNT = 0")
sets = conn.execute_all("SELECT 1 AS a; SELECT 2 AS b;")
sets.length      # => 2
sets.last.rows   # => [{ "B" => 2 }]
```

A call can declare its own count instead of asking the session, with the
`multi_statement_count:` keyword on `execute` and `execute_all`:

```ruby
sets = conn.execute_all("SELECT 1 AS a; SELECT 2 AS b;", [], multi_statement_count: 2)
```

The count says how many statements that one call carries, `0` for any number. It
travels with that request and outranks the session's `MULTI_STATEMENT_COUNT` for it,
but changes no session state — nothing to save and put back, and a connection shared
between threads is unaffected. Left out, nothing is sent and the session's value
decides, which is 1 until it is told otherwise.

If any statement in the string fails the whole call raises and no result sets come
back — not even for the statements before it. The engine discards their effects
too: an `INSERT` followed by a failing statement leaves nothing behind, whether the
failure is a syntax error, a missing table or a division by zero.

### Connection options

Every option can be given as a keyword or in the DSN query string, the keyword
winning. Timeouts are in seconds and default to 10s to connect and 300s to wait for
a statement.

```ruby
Frostlake.connect(dsn, open_timeout: 5, read_timeout: 30)
Frostlake.connect("frostlake://localhost:18082/DB?open_timeout=5&read_timeout=30")
```

An `https://` DSN verifies the server certificate. Point at your own authority with
`ca_file`, or turn verification off for a self-signed server:

```ruby
Frostlake.connect("https://localhost:8443/DB", ca_file: "/etc/ssl/my-ca.pem")
Frostlake.connect("https://localhost:8443/DB?verify_ssl=false")
```

The server authenticates nobody, so a DSN carrying `user:password@` is rejected
rather than having the credentials quietly dropped.

`verify_ssl` accepts `true`/`false`, `yes`/`no` or `1`/`0`. The DSN query string
accepts `schema`, `open_timeout`, `read_timeout`, `verify_ssl`, `ca_file` and
`session_idle_limit`, and nothing else: an unknown parameter is refused rather than
ignored, so a misspelled `schema` cannot quietly leave you in the wrong one. The
same goes for `verify_ssl` and `ca_file` on a DSN that is not `https` — they are
refused however they were spelled, since they would do nothing. The path names one
database, so `frostlake://host/db/extra` is refused too.

### Session lifetime

A connection is one session on the engine, and the session is where the current
database and schema, session variables, `ALTER SESSION` settings, temporary tables and
an open transaction live. The engine ends a session after 30 minutes idle, when it is
released, or when the server restarts. From engine 0.1.0 on every answer says whether
the session it ran in is new (`newSession`), and the driver takes the first answer that
names a session as the sign of which kind of engine it is talking to.

**What is sent.** Every request after the first names the session. To an engine that
reports `newSession` it also sends `requireSession: true`, so a session the engine no
longer holds is refused (HTTP 404) instead of being quietly replaced by a fresh one in
which the statement would run somewhere else. An older engine is sent neither that
field nor the release below.

**After a lost session.** The refused statement did not run. If the lost session held
nothing a fresh one lacks, the driver starts a fresh session, puts the DSN's database and
schema back on it, and sends the statement once more; if that is refused too, it raises.
If the lost session held an open transaction, or context set up with `USE`,
`SET`/`UNSET`, `ALTER SESSION`, a temporary object or a `CREATE`/`DROP` of a database or
schema, running the statement again could put it somewhere its author did not intend, so
the driver raises `Frostlake::SessionLostError` instead, saying which. Either way the
connection stays usable: its next statement starts a fresh session on the DSN's database
and schema.

```ruby
begin
  conn.execute("INSERT INTO acc VALUES (2)")
rescue Frostlake::SessionLostError
  # The transaction and anything set up on the session are gone; start the unit of
  # work over. The connection itself is fine.
end
```

**Close.** `close` sends `DELETE /api/sessions/{id}`, which ends the session and rolls
back a transaction it left open. It is best effort and bounded (five seconds to connect
and five to be answered, or the connection's own timeouts when they are shorter), and it
never raises. Closing again sends nothing. An engine older than 0.1.0 has no such
endpoint, so it is not asked, and the session lingers until its idle expiry.

**Older engines.** Before 0.1.0 the engine quietly builds a fresh session for the id the
driver keeps sending, and nothing in the reply says so. Against such an engine a
connection that has been idle longer than `session_idle_limit` (1800 seconds by default,
matching the engine) re-applies the database and schema from the DSN before the next
statement. It stops doing that the moment you run a `USE` of your own, since the DSN no
longer describes where you are. Everything else a dropped session held — the warehouse,
the role, session variables, an open transaction — is gone, and no client can restore
it. An engine that reports `newSession` has no need of the timer, and the driver leaves
it off there.

```ruby
Frostlake.connect(dsn, session_idle_limit: 600)   # re-apply after ten idle minutes
Frostlake.connect("frostlake://host:18082/DB?session_idle_limit=0")  # never
```

### Errors

Everything the driver raises is a `Frostlake::Error`, so a single rescue still catches
the lot. The subclass says which kind it was:

| Class | Raised when |
| --- | --- |
| `Frostlake::ConnectionError` | the server is unreachable, unhealthy, or the request failed |
| `Frostlake::SessionLostError` | a `ConnectionError`: the engine no longer holds the session, and the transaction or context it held cannot be put back; the statement did not run |
| `Frostlake::QueryError` | the engine rejected the statement; the message is the engine's |
| `Frostlake::UsageError` | the driver was misused: bad DSN, closed connection, unbindable value |

### Threads

A `Connection` is one socket and one server-side session, so statements on it are
serialized and it is safe to share. A transaction is session state, though — don't
drive one from several threads at once. Use a connection per thread if you want
statements to actually run in parallel.

## Running the tests

The integration tests boot a real server from the engine's compiled classes:

```sh
export JAVA_HOME=/path/to/jdk17
export FROSTLAKE_CLASSPATH="/path/to/frostlake/engine/target/classes:<engine deps>"
rake test        # or: ruby test/test_frostlake.rb
```

Without `FROSTLAKE_CLASSPATH` the integration tests skip themselves and only the
substitution unit tests run.

## Testkit corpus runner

`testkit_runner.rb` replays the engine's testkit corpus — the language-neutral JSON
suites in `frostlake/engine/src/test/resources/testkit/suites`, format in the `SCHEMA.md`
beside them — through this driver, and compares every cell as the driver hands it back.
`FL_CORPUS` names that testkit directory, best as an absolute path. With it set, the test
suite replays the corpus as one more test, which fails when any case does; without it, or
with neither `FROSTLAKE_URL` nor `FROSTLAKE_CLASSPATH` to replay against, that test is
skipped:

```sh
FL_CORPUS=/path/to/frostlake/engine/src/test/resources/testkit ruby test/test_frostlake.rb
```

The runner also runs on its own:

```sh
FL_CORPUS=/path/to/frostlake/engine/src/test/resources/testkit \
  FROSTLAKE_URL=frostlake://127.0.0.1:18082 ruby testkit_runner.rb
```

Every case recreates `test_db`, so point it at a scratch server — or leave
`FROSTLAKE_URL` out and it boots one of its own from `FROSTLAKE_CLASSPATH`, in the test
suite too. `FROSTLAKE_TESTKIT_FILTER=word1,word2` replays only the suites whose name
contains one of the words.

Each case runs on a connection of its own, after the reset the corpus prescribes; a case
skipped for `ruby` or `http` reports SKIP. The report, `results/testkit-ruby.tsv` unless
`FROSTLAKE_TESTKIT_REPORT` says otherwise, holds one row per case (`suite`, `test`,
`status`, `failedStep`, `detail`, `ms`). Beside it `missing-apis-ruby.md` lists the checks
the protocol cannot express — an expected error's code or SQLSTATE — which are recorded
rather than failed. The run ends with `testkit [ruby]: <P> passed, <F> failed, <S> skipped`
and exits 1 when any case failed, or when `FL_CORPUS` holds no suites.

## Protocol

One `POST /api/execute` per statement with `{ sql, sessionId, autoCommit }` — plus
`multiStatementCount` when a call declares one, and nothing at all when it does not; the server
issues the `sessionId` on first contact and the driver echoes it back, so session state
(current database/schema, transactions) persists across statements. To an engine that
reports `newSession` the driver adds `requireSession: true`, and `close` sends
`DELETE /api/sessions/{id}` (see [Session lifetime](#session-lifetime)). `GET /api/health`
backs `Frostlake.connect`'s reachability check.

## License

Apache-2.0 — see [LICENSE](LICENSE).
