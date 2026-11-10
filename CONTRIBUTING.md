# Contributing to Fettle

## Setup

```bash
# Install development tools
brew install shfmt shellcheck bats-core golangci-lint

# Install goimports for better Go formatting
go install golang.org/x/tools/cmd/goimports@latest

# Install pre-commit hook (runs format/lint checks on every commit)
git config core.hooksPath .githooks
```

## Development

Run quality checks before committing (auto-formats code):

```bash
./scripts/check.sh
```

Run tests:

```bash
./scripts/test.sh
```

## Code Style

### Basic Rules

- Bash 3.2+ compatible (macOS default)
- 4 spaces indent
- Use `set -euo pipefail` in all scripts
- Quote all variables: `"$variable"`
- Use `[[ ]]` not `[ ]` for tests
- Use `local` for function variables, `readonly` for constants
- Function names: `snake_case`
- BSD commands not GNU (e.g., `stat -f%z` not `stat --format`)

Config: `.editorconfig` and `.shellcheckrc`

### File Operations

**Always use safe wrappers, never `rm -rf` directly:**

```bash
# Single file/directory
safe_remove "/path/to/file"

# Purge files older than 7 days
safe_find_delete "$dir" "*.log" 7 "f"

# With sudo
safe_sudo_remove "/Library/Caches/com.example"
```

See `lib/core/file_ops.sh` for all safe functions.

### Pipefail Safety

All commands that might fail must be handled:

```bash
# Correct: handle failure
find /nonexistent -name "*.cache" 2>/dev/null || true

# Correct: check array before use
if [[ ${#array[@]} -gt 0 ]]; then
    for item in "${array[@]}"; do
        process "$item"
    done
fi

# Correct: arithmetic operations
((count++)) || true
```

### Error Handling

```bash
# Network requests with timeout
result=$(curl -fsSL --connect-timeout 2 --max-time 3 "$url" 2>/dev/null || echo "")

# Command existence check
if ! command -v brew >/dev/null 2>&1; then
    log_warning "Homebrew not installed"
    return 0
fi
```

### UI and Logging

```bash
# Logging
log_info "Starting cleanup"
log_success "Cache cleaned"
log_warning "Some files skipped"
log_error "Operation failed"

# Spinners
with_spinner "Cleaning cache" rm -rf "$cache_dir"

# Or inline
start_inline_spinner "Processing..."
# ... work ...
stop_inline_spinner "Complete"
```

### Debug Mode

Enable debug output with `--debug`:

```bash
fettle --debug clean
./bin/clean.sh --debug
```

Modules check the internal `MO_DEBUG` variable:

```bash
if [[ "${MO_DEBUG:-0}" == "1" ]]; then
    echo "[MODULE] Debug message" >&2
fi
```

Format: `[MODULE_NAME] message` output to stderr.

## Requirements

- macOS 12 or newer, works on Intel and Apple Silicon
- Default macOS Bash 3.2+; administrator privileges are required for system-level cleanup tasks
- Command Line Tools (`xcode-select --install`) for curl, tar, and standard utilities
- Go 1.26+ is required to build the `fettle status` and `fettle analyze` TUI binaries locally.

## Go Components

`fettle status` and `fettle analyze` use Go with Bubble Tea for interactive dashboards.

**Code organization:**

- Each module is split into focused files by responsibility.
- `cmd/analyze/` owns disk traversal, caching, deletion, navigation, and rendering.
- `cmd/status/` keeps collection, automation output, preferences, and rendering separate.

**Development workflow:**

- Format code with `./scripts/check.sh --format`
- Run `go vet ./cmd/...` to check for issues
- Build with `go build ./...` to verify all packages compile

**Building Go Binaries:**

For local development:

```bash
# Build binaries for current architecture
make build

# Or run directly without building
go run ./cmd/analyze
go run ./cmd/status
```

For releases, GitHub Actions builds architecture-specific binaries automatically.

**Guidelines:**

- Keep files focused on a single responsibility
- Use named constants instead of magic numbers
- Use context for timeout control on external commands
- Add comments explaining the **why** behind non-obvious logic, not just what the code does

## Pull Requests

1. Fork and create a branch from `fettle`
2. Make changes
3. Run checks: `./scripts/check.sh`
4. Commit and push
5. Open a PR targeting `fettle`

CI will verify formatting, linting, and tests.

## Licensing

Fettle is GPL-3.0, like Mole, the project by tw93 it is built on, and that is the licence your contribution carries. There is no CLA, and you keep your copyright.
