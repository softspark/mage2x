# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.x     | Yes       |

## Reporting a Vulnerability

**Do NOT open a public GitHub issue for security vulnerabilities.**

Email: biuro@softspark.eu

Response SLA: 48 hours.

Process:
1. Report via email with description and reproduction steps
2. We confirm receipt within 48 hours
3. We investigate and develop a fix
4. We coordinate disclosure and credit the reporter

## Security Design

### It runs what you already can

mage2x never authenticates to anything. It shells out to `docker`, `podman` or
`kubectl` using the credentials, contexts and RBAC already configured on the
machine. It cannot reach a cluster the operator cannot reach, and it holds no
tokens, no kubeconfig parsing beyond the context name, and no secrets of its own.

### The guard is a speed bump, not a permission model

The production confirmation exists to stop a mistake, not an attacker. Anyone
who can run `m2x` can run `kubectl` directly. Treat it as ergonomics with a
safety catch; RBAC remains the security boundary.

`M2X_ASSUME_YES=1` disables the prompt by design, for automation. A destructive
verb with no terminal attached is refused rather than executed, so a script that
inherits the variable by accident still cannot silently restart production.

### No eval, no shell interpolation of target names

Target names come from the runtime's own listing and are passed to the engine as
argument vectors, never spliced into a shell string. A container named with shell
metacharacters cannot execute anything.

### No network of its own

No telemetry, no update checks, no outbound requests. Every byte on the wire is
sent by the container engine you invoked.

## Scope

**In scope:**
- Command injection through target names, verbs or catalogue arguments
- The production guard passing when it should refuse
- Leaking a token, kubeconfig path or credential into output or process arguments
- The installer writing outside `$ZSH_CUSTOM/plugins` or `~/.zshrc`

**Out of scope:**
- `M2X_ASSUME_YES=1` and other documented overrides
- Security of docker, podman, kubectl, or the clusters they reach
- Anything an operator could already do with the underlying CLI
- Social engineering
