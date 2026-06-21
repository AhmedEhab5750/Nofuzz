# Contributing to Nofuzz

Contributions are welcome - whether that's a bug fix, a new feature, or
improved docs.

## How to contribute

1. Fork the repo and create a branch off `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```
2. Make your changes. Keep the script bash-compatible and dependency-light -
   the whole point of Nofuzz is that it only needs `bash` and `curl`.
3. Test your changes locally:
   ```bash
   bash -n simple-dirb.sh   # syntax check
   ./simple-dirb.sh <test_url> <wordlist>  # functional test
   ```
4. Commit with a clear message and open a Pull Request describing what
   changed and why.
5. Submit the PR against `main`.

## Reporting bugs / requesting features

Open an issue with:
- What you expected to happen
- What actually happened (include relevant output/error messages)
- Your OS, bash version, and curl version if relevant

## Code style

- Use `set -uo pipefail` at the top.
- Prefer clear variable names and inline comments over cleverness.
- Don't add dependencies beyond `bash` + `curl` without strong justification -
  open an issue first if you think one is needed.
- Update the README when adding flags or environment variables.
