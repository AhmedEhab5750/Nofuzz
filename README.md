# nofuzz

A minimal, transparent, curl-based directory/file brute forcer for web targets.

No hidden matcher state, no silent filtering logic you can't see, no "magic" wordlist
preprocessing. Every request nofuzz sends, and the raw result behind it, is visible to you.

## Why nofuzz exists

Built after repeatedly hitting cases where popular fuzzing tools returned **zero output**
when given a custom wordlist - even though manually requesting the exact same paths in a
browser turned up live `200`/`403`/`404` responses. Switching back to the tool's own
default wordlist would make output reappear; the custom wordlist case kept returning
nothing, with no clear indication of why.

nofuzz takes the opposite approach: it's a thin, auditable wrapper around `curl`. There's
no internal scoring, no auto-calibration, no baseline-response heuristics deciding what
counts as "interesting" behind your back. If a request goes out, you can see it. If a
result is hidden, it's because *you* told it to hide that exact status code - nothing
else.

## Features

- Curl-based requests - uses the same HTTP client you already trust and debug with
- Custom wordlists, with optional extension appending (`-e php,bak,old`)
- Status code filtering: exclude (`-x`) or match-only (`-m`)
- Concurrent requests via `xargs -P`, with a configurable thread count
- Per-request timeout and optional delay (basic rate-limit friendliness)
- Custom HTTP method, User-Agent, redirect following, and `-k` for self-signed/internal
  TLS certs
- Sampling mode (`-s N`) to test a subset of a huge wordlist before committing to a full run
- **Error/timeout filtering** - hide connection-error or timeout lines from the terminal
  without losing them
- **Automatic retry log** - every failed request (timeout or connection error) is written
  to a `nofuzz_retry_<timestamp>.txt` file, so a flaky target or a too-aggressive timeout
  doesn't mean lost coverage
- **Auto-retest** (`-r [N]`) - after the main wordlist finishes, automatically loop back
  over whatever errored or timed out, in the same run, up to N passes
- **Retest mode** (`-R`) - feed a saved retry file back into nofuzz in a later run to
  re-check only what failed, typically with a longer timeout or fewer threads

## Requirements

- `bash` (4+)
- `curl`
- Standard coreutils: `awk`, `xargs`, `flock`, `mktemp` (present by default on virtually
  every Linux distro and macOS with GNU coreutils / `flock` available)

No other dependencies. Nothing to `pip install`, no Go binary to fetch.

## Installation

```bash
git clone https://github.com/AhmedEhab5750/nofuzz.git
cd nofuzz
chmod +x nofuzz.sh
```

Optionally drop it somewhere on your `$PATH`:

```bash
sudo cp nofuzz.sh /usr/local/bin/nofuzz
```

## Usage

```bash
./nofuzz.sh <base_url> <wordlist_file> [options]
./nofuzz.sh -h | --help
```

### Options

| Flag | Long form | Description |
|---|---|---|
| `-e` | `--ext EXT1,EXT2` | Extensions to append (skips a word if it already ends in that ext) |
| `-t` | `--threads N` | Concurrent workers (default `10`) |
| `-d` | `--delay SEC` | Delay per request, applied per worker (default `0`) |
| `-T` | `--timeout SEC` | Per-request timeout in seconds (default `10`) |
| `-A` | `--user-agent STR` | Custom User-Agent string |
| `-X` | `--method METHOD` | HTTP method (default `GET`) |
| `-x` | `--exclude-status CODES` | Comma list of status codes to hide, e.g. `403,404` |
| `-m` | `--match-status CODES` | Comma list of status codes to *only* show (overrides `-x`) |
| `-L` | `--follow-redirects` | Follow redirects (`curl -L`) |
| `-k` | `--insecure` | Skip TLS certificate verification |
| `-s` | `--sample N` | Only send the first N words from the built path list |
| `-E` | `--hide-errors` | Don't print connection-error lines to the terminal |
| `-W` | `--hide-timeouts` | Don't print timeout lines to the terminal |
| `-R` | `--retest` | Retest mode — treat the wordlist arg as a saved retry file |
| `-r` | `--auto-retest [N]` | Auto-retest errors/timeouts in this same run, up to N passes (default 1) |
| `-h` | `--help` | Show the help menu and exit |

> `-E`/`-W` only affect what's printed to your screen. Failed paths are **always** logged
> to the retry file regardless of these flags - they only control terminal noise, not
> coverage.

### Output files

Every run produces (in the current directory):

- **`nofuzz_results_<timestamp>.txt`** - every request that passed your `-x`/`-m` filter,
  one line per hit: status code, response size, response time, full URL.
- **`nofuzz_retry_<timestamp>.txt`** - paths that timed out or errored (connection refused,
  DNS failure, TLS error, etc.), one path per line. Deleted automatically if nothing
  failed.

## Examples

Basic scan with two extensions and 20 threads:

```bash
./nofuzz.sh https://target.com wordlist.txt -e php,bak -t 20
```

Only show `200` and `500` responses, follow redirects, and keep the terminal quiet about
errors/timeouts (they're still logged):

```bash
./nofuzz.sh https://target.com wordlist.txt -m 200,500 -L -E -W
```

Sample 500 entries from a huge wordlist first, skipping TLS verification on an internal host:

```bash
./nofuzz.sh https://internal.local wordlist.txt -s 500 -k
```

Hide noisy 403/404s, use a custom User-Agent, 5 threads with a small delay to stay polite
on a rate-limited target:

```bash
./nofuzz.sh https://target.com wordlist.txt -x 403,404 -A "Mozilla/5.0 research-scan" -t 5 -d 0.5
```

## Retesting failed requests

There are two ways to recover requests that errored or timed out.

### Automatic, same-run (`-r`)

Add `-r` to have nofuzz loop back over whatever failed, right after the main wordlist
finishes - no second command needed:

```bash
./nofuzz.sh https://target.com wordlist.txt -T 5 -r
```

By default this does one extra pass. Pass a number for more rounds, e.g. on a target
that's recovering from rate-limiting:

```bash
./nofuzz.sh https://target.com wordlist.txt -T 5 -r 3
```

Each pass only re-checks what failed in the *previous* pass, and the loop stops as soon as
a pass comes back with zero failures - so it doesn't burn through all N passes if the
target recovers after the first retry. Whatever is still failing after the last pass is
written to the retry file as usual, so you can come back to it later.

### Manual, later run (`-R`)

If you'd rather inspect the failures before deciding what to do (or you're picking this up
in a new terminal/session entirely), point a fresh invocation at the retry file with `-R`:

```
Retry file: nofuzz_retry_20260622_153000.txt (37 entries)
Retest later with: ./nofuzz.sh https://target.com nofuzz_retry_20260622_153000.txt -R
```

```bash
./nofuzz.sh https://target.com nofuzz_retry_20260622_153000.txt -R -T 20 -t 5
```

In retest mode, the wordlist file is used as-is (no extension building, no dedup logic
beyond removing exact duplicate lines) - it's expected to already be a flat list of paths,
which is exactly the format the retry file is written in. `-r` and `-R` can be combined
too, e.g. to auto-retest within that manual retest run as well.

## How it decides pass/fail/error

For every path, nofuzz sends one `curl` request with `--max-time <timeout>` and reads back
the HTTP status code, response size, and response time via `curl -w`.

- If curl's exit code is `28` (operation timeout), the request is logged as `[TIMEOUT]`.
- If curl fails for any other reason (connection refused, DNS failure, TLS error, etc.) or
  returns no status code, it's logged as `[ERR ]` along with curl's exit code.
- Both cases are written to the retry file. Neither is silently dropped.
- Otherwise the status code is checked against `-m`/`-x` and, if it passes, printed and
  appended to the results file.

There's no response-size baseline, no "this looks like a soft-404 page" heuristic, and no
automatic filtering beyond what you explicitly configure with `-x`/`-m`. What you see is
what curl actually got back.

## A note on scope and authorization

nofuzz sends real HTTP requests to whatever target you point it at. Only use it against
systems you're authorized to test - your own infrastructure, or targets explicitly in
scope under a bug bounty program or other written authorization. You are responsible for
how you use this tool.

## License

MIT - see [LICENSE](LICENSE).

## Contributing

Issues and PRs welcome. The goal of this project is to stay small, dependency-free, and
fully transparent about what it's doing - please keep that in mind for any feature
proposals (no hidden heuristics, no opaque "smart" filtering).
