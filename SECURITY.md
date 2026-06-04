# Security Policy

## Supported Versions

| Version | Support Status |
|---------|---------------|
| 7.3.x (current) | Full support — security and bug fixes |
| 7.2.x | Security fixes only |
| < 7.2 | No longer supported |

## Reporting a Vulnerability

**Do not open a public GitHub Issue for security vulnerabilities.**

Report security issues privately via [GitHub Security Advisories](https://github.com/ek33450505/claude-agent-team/security/advisories/new).
This keeps the details confidential until a fix is released.

### What to include

- CAST version (`cat ~/.claude/cast-version`)
- Operating system and shell version
- The hook or script involved (`post-tool-hook.sh`, `cast-memory-router.py`, etc.)
- Steps to reproduce
- Potential impact assessment

### Response timeline

| Severity | Acknowledgement | Target remediation |
|----------|-----------------|--------------------|
| Critical | 48 hours | 14 days |
| High | 48 hours | 30 days |
| Medium/Low | 5 business days | Next release |

We will keep you updated throughout the remediation process and credit you in the release notes unless you prefer to remain anonymous.

## Out of Scope

The following are not in scope for this security policy:

- Social engineering attacks
- Physical access attacks
- Vulnerabilities in the Claude API itself (report to [Anthropic](https://www.anthropic.com/security))
- Vulnerabilities in third-party tools (bats, jq, etc.) — report to those projects directly

## Disclosure Policy

We follow [responsible disclosure](https://en.wikipedia.org/wiki/Responsible_disclosure). Once a fix is available, we will:

1. Release the patched version
2. Publish a security advisory with CVE (if applicable)
3. Credit the reporter (with permission)
