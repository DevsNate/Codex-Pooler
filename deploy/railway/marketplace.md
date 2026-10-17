# Deploy and Host Codex Pooler on Railway

The full featured self-hosted Codex gateway, for teams, agents and you

Codex Pooler brings your Codex accounts together behind one endpoint for coding tools. Organize accounts into Pools, issue scoped API keys, manage quota-aware routing, and inspect usage from an operator dashboard. It supports Codex backend clients and selected OpenAI-compatible SDK routes. Codex Pooler is source available and free to self-host under the Elastic License 2.0.

## About Hosting Codex Pooler

This template deploys Codex Pooler and PostgreSQL together. It generates independent application secrets and the database password, connects the services over Railway's private network, creates a public HTTPS domain for Pooler, and mounts persistent storage for PostgreSQL. Database migrations and the bundled pricing import run before each application deployment. Readiness must pass before the new version becomes active.

After deployment, open the generated domain and create the first owner account. Then create a Pool, connect an authorized Codex account, and issue a Pool API key for your tools. No source build, Redis service, or manual database migration is needed. Keep the application at one replica with Serverless disabled so scheduled jobs continue running.

## Common Use Cases

- Connect several coding tools to one managed Codex endpoint with separate, revocable API keys.
- Share authorized accounts with a team while applying model and usage limits to each key.
- Route requests across account quotas and inspect activity, request outcomes, and usage from one dashboard.

## Dependencies for Codex Pooler Hosting

- A Railway account with available usage credit or a suitable paid plan.
- PostgreSQL 18 with persistent storage, included in this template.
- At least one authorized Codex account, connected after installation.
- Outbound HTTPS access to the upstream provider.

### Configuration and operations

The template runs web requests, background jobs, and scheduled tasks in one application service. Only Pooler receives a public domain; the database stays private. Preserve the database volume and generated encryption keys across upgrades. Back up both the database and the keys: neither replaces the other.

Railway charges for infrastructure; Codex account subscriptions and provider usage are separate. Trial credits are suitable for evaluation. Review your usage and configure a spending limit before leaving a deployment running.

Railway applies a 15-minute duration limit to HTTP requests, including SSE, and a five-minute inactivity limit. Websockets are exempt from those platform limits. Keep this template at one application replica; clustered deployments require additional configuration.

- [Deployment and upgrade guide](https://www.codex-pooler.com/docs/deployment/railway/)
- [Client setup guides](https://www.codex-pooler.com/docs/clients/codex-cli-desktop/)
- [Source and releases](https://github.com/icoretech/codex-pooler)
- [License](https://github.com/icoretech/codex-pooler/blob/main/LICENSE.md)

## Why Deploy Codex Pooler on Railway?

Railway provisions the application, private service networking, public HTTPS, and the PostgreSQL volume from one template. You can get a self-hosted instance online without maintaining a server or installing Docker locally, while keeping control of your operator accounts, Pools, API keys, and deployment.
