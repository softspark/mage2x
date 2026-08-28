# Contributing to mage2x

Thanks for wanting to help. mage2x is small on purpose — it guards git
identity and does nothing else — so the bar for new surface area is high, and
the bar for correctness is higher.

## Workflow

1. Fork, then branch from `main`
2. Make the change, with a test that fails without it
3. Run the gates below
4. Open a PR against `main`

## Branch Naming

| Prefix | Use |
|--------|-----|
| `feat/` | New feature |
| `fix/` | Bug fix |
| `refactor/` | No behavior change |
| `docs/` | Documentation only |
| `test/` | Tests only |

## Commit Conventions

[Conventional Commits](https://www.conventionalcommits.org/). Subject under 72
characters, one logical change per commit. Never pass `--no-verify`; if a hook
fails, fix the cause. Never add AI co-authorship trailers.

## CI Requirements

Everything below must pass locally before you open a PR:

```bash
shellcheck lib/guard.sh lib/pre-commit lib/pre-push tests/run.sh
node --check bin/mage2x-install.mjs
zsh -n mage2x.plugin.zsh && zsh -n _mage2x
./tests/run.sh
```

The suite builds a throwaway `HOME` and never touches your real git config.

## Coding Standards

**The adapter contract is the boundary.** Nothing outside `lib/rt-*.zsh` may
assume a particular engine. Adding a runtime means one new file implementing
`available`, `context`, `list`, `exec`, `shell`, `logs`, `restart`, `forward` —
and no changes to any verb or catalogue entry.

**Ambiguity is an error, never a choice.** A fragment matching several workloads
must list them and stop. Picking the first match is how a monitoring tool ended
up watching a `mysql-backup` sidecar instead of `mysqld`.

**Only destructive verbs prompt.** A confirmation that fires on `logs` is
dismissed reflexively within a day and then protects nothing. Guard state
changes; leave reads alone.

**`${x:+-flag $x}` expands to ONE word in zsh.** The engine then receives
`-u www-data` as a single argument and reports it cannot find that user. Build a
flag array instead. This has already been a bug once.

**`(#i)` needs `extendedglob`**, which `emulate -L zsh` turns off. Lowercase with
`${x:l}` and compare without the flag, or the pattern silently never matches —
which is how production detection shipped broken in the first draft.

**A function whose stdout is its return value must send every diagnostic to
stderr.** `_m2x_resolve` prints the resolved name; a candidate list printed to
stdout vanishes into the command substitution, leaving a refusal that is correct
but silent. Worse than guessing, because nobody learns what to type.

**Kubernetes is not docker with a different binary.** `restart` rolls the owning
workload, targets carry a namespace, and there is no routable pod IP. Where the
model genuinely differs, say so rather than emulating.

## What to Contribute

Good first contributions:
- Catalogue entries for Magento commands that are missing
- Completion improvements
- A runtime adapter (nerdctl, containerd, Docker Swarm)

Open an issue first for:
- New verbs, or changes to the adapter contract
- Anything that relaxes the production guard or the ambiguity refusal
- Support for a platform beyond Magento

## Security

No secrets in code, tests or fixtures. Never log a token or a key path. See
[SECURITY.md](../SECURITY.md); report vulnerabilities to biuro@softspark.eu
rather than in a public issue.
