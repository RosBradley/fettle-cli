---
name: CLI Bug Report
about: Report a bug in Glimwell
title: '[BUG] '
labels: bug
assignees: ''
---

## Before submitting

Run `glimwell update` to install the latest stable version, then check `glimwell --version`. Reproduce the problem with that version. If updating itself fails, report that failure and your installed version.

- [ ] I updated and reproduced the problem, or this report explains why I cannot update.

## Describe the bug

Describe what happened. English is preferred so more contributors can help triage.

If you believe the issue may allow unsafe deletion, path validation bypass, privilege boundary bypass, or release/install integrity issues, do not file a public bug report. Report it privately using the contact details in [SECURITY.md](https://github.com/RosBradley/glimwell-cli/blob/glimwell/SECURITY.md).

## Steps to reproduce

1. Run command: `glimwell ...`
2. ...
3. See error

## Expected behavior

What did you expect to happen instead?

## Debug logs

Run the command with `--debug` and paste the output:

```bash
glimwell <command> --debug
# Example: glimwell clean --debug
```

<details>
<summary>Debug output</summary>

```text
Paste debug output here
```

</details>

## Environment

Paste the output of `glimwell --version` from the version used to reproduce the problem:

```text
Paste glimwell --version output here
```

## Additional context

Screenshots, error messages, or related details (optional).
