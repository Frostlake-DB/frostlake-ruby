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

Requires a Frostlake engine **0.0.7 or newer**. Ask a running server which one it is with
`SELECT CURRENT_VERSION()` — every release answers it, so the check works against any engine.

The driver versions independently of the engine: it speaks the HTTP protocol, not
the jar, so this is a floor rather than a lockstep pin.

One behaviour does depend on the engine: a `TIMESTAMP_TZ` column only reports back the
UTC offset it was given from engine **0.1.0** on. Against an older engine a bound `Time`
still round-trips, but the offset comes back as `+00:00`.

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

### Result types

Fixed-point `NUMBER` keeps the exact digits the engine sent: `BigDecimal` when the
column has a scale, `Integer` when it does not (of any size — Ruby integers are
arbitrary precision). `FLOAT`/`DOUBLE`/`REAL` are genuine binary floats and stay
`Float`. `BOOLEAN` becomes `true`/`false`, `DATE` a `Date`, `TIMESTAMP*` a `Time`,
`BINARY` a binary-encoded `String`; `TIME` and semi-structured values keep their
wire shape as strings.

Each entry in `columns` is a hash of `{ name:, data_type:, scale: }`, carrying the
engine's own type name.

A result set arrives as one JSON body and is fully materialised — the driver holds
every row in memory, and the protocol offers no cursor to page through a large
`SELECT`. Bound the query rather than expecting the driver to stream it.

Exact decimals need `bigdecimal`, which ships with Ruby. If it cannot be loaded —
a bundler setup on Ruby ≥ 3.4 without it in the Gemfile — those cells fall back to
`Float` rather than the driver failing to load.

### Several statements at once

`execute` returns the first result set. `execute_all` returns every one, in order:

```ruby
sets = conn.execute_all("SELECT 1 AS a; SELECT 2 AS b;")
sets.length      # => 2
sets.last.rows   # => [{ "B" => 2 }]
```

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

### Idle sessions

The engine drops a session after 30 minutes idle and then quietly builds a fresh one
for the id the driver keeps sending. A connection left sitting therefore loses the
database and schema it had selected, and **nothing in the reply says so** — the id
you sent is echoed back either way, and `/api/sessions` reports only a count, so the
driver cannot ask whether its session survived.

What it does instead: once a connection has been idle longer than
`session_idle_limit` (1800 seconds by default, matching the engine), it re-applies
the database and schema from the DSN before the next statement. It stops doing that
the moment you run a `USE` of your own, since the DSN no longer describes where you
are.

```ruby
Frostlake.connect(dsn, session_idle_limit: 600)   # re-apply after ten idle minutes
Frostlake.connect("frostlake://host:18082/DB?session_idle_limit=0")  # never
```

Everything else a dropped session held — the warehouse, the role, session variables,
an open transaction — is gone, and no client can restore it. If a connection may idle
for long stretches, reconnecting is the dependable answer.

### Errors

Everything the driver raises is a `Frostlake::Error`, so a single rescue still catches
the lot. The subclass says which kind it was:

| Class | Raised when |
| --- | --- |
| `Frostlake::ConnectionError` | the server is unreachable, unhealthy, or the request failed |
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

## Protocol

One `POST /api/execute` per statement with `{ sql, sessionId, autoCommit }`; the server
issues the `sessionId` on first contact and the driver echoes it back, so session state
(current database/schema, transactions) persists across statements. `GET /api/health`
backs `Frostlake.connect`'s reachability check.

## License

Apache-2.0 — see [LICENSE](LICENSE).
