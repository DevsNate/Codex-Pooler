# Codex Pooler Pricing And Availability

Last reviewed: 2026-10-17
Canonical docs: https://www.codex-pooler.com/docs/

Codex Pooler is self-hosted software with published releases. It has no hosted plan and no commercial pricing page. Documented deployment options are Docker Compose, Railway in your own account, and the Helm chart.

## Public availability

- Release status: versioned releases published on GitHub
- Releases: https://github.com/icoretech/codex-pooler/releases
- Container image: `ghcr.io/icoretech/codex-pooler`
- Helm chart: `icoretech/codex-pooler` in the iCoreTech Helm repository, https://icoretech.github.io/helm
- Hosted service: none
- Self-hosted Docker Compose path: documented
- Railway path in your own account: [documented](https://www.codex-pooler.com/docs/deployment/railway/), infrastructure billed by Railway
- Self-hosted Kubernetes Helm path: documented

## License and hosted use

- Repository license: Elastic License 2.0
- Public hosted plan: none
- Managed-service pricing: none
- Self-hosted use: free, with no subscription tier or seat pricing

Read `LICENSE.md` before redistributing, modifying, or providing managed access to Codex Pooler. These docs describe self-hosted operation and do not publish a hosted or managed-service offer.

## Operator cost considerations

Codex Pooler documentation does not define subscription tiers or seat pricing. Operators should plan for their own infrastructure costs, database storage, Kubernetes or Docker hosting, monitoring, and any upstream provider account costs they are already authorized to use.

On Railway, budget for the always-running application, PostgreSQL, persistent storage, backups, and network usage. Trial credit does not make the deployment free to run indefinitely. Consult [Railway pricing](https://docs.railway.com/pricing) and set [usage limits](https://docs.railway.com/pricing/cost-control) for your account.

## Credential boundary

Codex Pooler does not replace upstream account authorization. Operate only accounts you are allowed to use, keep Pool API keys separate from operator MCP tokens, and do not put raw credentials or provider account material in docs, tickets, screenshots, logs, or prompts.
