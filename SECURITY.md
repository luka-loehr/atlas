# Security

Atlas holds people's photos and files, so security reports are taken
seriously.

## Reporting a vulnerability

Please **do not open a public issue.** Report it privately through GitHub:
on the repository's **Security** tab, choose **Report a vulnerability**. Include
what an attacker can do, the steps to reproduce and the version or commit.

You will get an answer within a week. Once a fix is released, the report is
credited to you unless you prefer otherwise.

## Scope

Atlas is designed to be reached only over a private network (a Tailscale
tailnet) with one bearer token per server; see the security section of
[docs/OVERVIEW.md](docs/OVERVIEW.md). Reports are most useful about:

- the server's API and its authentication (`crates/server`)
- share links and the share worker (`share/`), which are reachable from the
  internet
- the apps' handling of the server token and of `atlas://` links
- the install scripts and service units (`scripts/`)

Only the latest release is supported.
