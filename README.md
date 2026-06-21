# Nofuzz

A minimal, dependency-light directory/file brute forcer built on `curl` and
`xargs`. No Go, no Python, no third-party libraries - just bash and core
utils. Useful when you need a fast sanity check on a host without pulling in
a heavier tool like ffuf or gobuster.

# Nofuzz

A minimal, dependency-light directory/file brute forcer built on `curl` and
`xargs`. No Go, no Python, no third-party libraries - just bash and core
utils. Useful when you need a fast sanity check on a host without pulling in
a heavier tool like ffuf or gobuster.

## Why Nofuzz

Built after running into cases where popular fuzzing tools gave zero output
when used with a custom wordlist, even though manually testing the same paths
in a browser turned up live 200/403/404 responses. Switching to the tool's
own default wordlist would produce output again, but the custom wordlist
case kept returning nothing.

Nofuzz uses a simple curl-based approach with no hidden matcher/filter state,
so you can always see exactly what's being requested and why a result shows
or doesn't.

## Usage

```bash
chmod +x nofuzz.sh
./nofuzz.sh <base_url> <wordlist_file> [extensions]
```

**Example:**
```bash
./nofuzz.sh https://target.com/ /usr/share/wordlists/dirb/common.txt "php,js,bak"
```

This tests every word in the wordlist as a path, and additionally tests
`word.php`, `word.js`, `word.bak` for each entry if extensions are given.

## Options (environment variables)

| Variable | Default | Description |
|---|---|---|
| `THREADS` | `10` | Number of parallel `curl` workers (`xargs -P`) |
| `DELAY` | `0` | Seconds to sleep after each request, per worker |
| `TIMEOUT` | `10` | Max seconds per request (`curl --max-time`) |
| `USER_AGENT` | `Mozilla/5.0 ... curl-dirb/1.0` | Custom User-Agent string |

**Example with tuning:**
```bash
THREADS=20 DELAY=0.5 TIMEOUT=5 ./nofuzz.sh https://target.com/ wordlist.txt
```

## Output

Every response (except connection failures/timeouts) is printed to the
terminal and appended to a timestamped file in the current directory:

```
dirb_results_YYYYMMDD_HHMMSS.txt
```

Each line follows the format:
```
[<http_code>] <size_in_bytes>B <response_time>s <full_url>
```

Connection failures/timeouts print as `[ERR ]` to the terminal only - they are
**not** written to the results file.

## Requirements

Just `bash` and `curl` - both present on virtually every Linux/macOS system by
default. No installation needed.

## Notes & limitations

- No automatic filtering of common false positives (e.g. a wildcard `200` on
  every path for SPAs/custom 404 pages) - review results manually or pipe
  through `grep`/`awk` to filter by code or size.
- `DELAY` is applied per worker, not globally - with `THREADS=10` and
  `DELAY=1`, effective request rate is still up to 10 req/s, not 1 req/s.
- No recursion - only tests the wordlist against the single base URL given.
- Trailing slash on the base URL is normalized automatically if missing.

## Disclaimer

This tool is intended for use only against systems and assets you are
explicitly authorized to test - for example, targets in scope of a bug bounty
or VDP program you're enrolled in, or infrastructure you own. See
[DISCLAIMER.md](./DISCLAIMER.md) for the full statement.

## Contributing

Issues and PRs welcome - see [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

[MIT](./LICENSE)
