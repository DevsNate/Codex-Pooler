# Railway template

The [Railway deployment guide](https://www.codex-pooler.com/docs/deployment/railway/) is the installation entry point. The template creates one application service and one private PostgreSQL service with persistent storage, generated secrets, automatic migrations, and a public application domain.

This directory keeps the template's source configuration and marketplace overview reviewable:

- `template.json` is Railway's exported `serializedConfig`, including generator expressions rather than resolved secrets. Railway deploys the configuration saved in its template composer; it does not automatically import this file from the repository.
- `marketplace.md` is the overview used by the marketplace listing.

Before publishing a template update, pin the intended release image in the composer, apply the changes, export its configuration again, and compare it with `template.json`. Test a fresh deployment from that exact template, including migration failure, recovery, and persistence across application and database restarts. A locally uploaded candidate build does not certify a different published image.

Keep the application at one replica with Serverless disabled. Preserve all generated secrets and the PostgreSQL volume when upgrading an existing installation. The application pre-deploy command runs migrations and pricing import; the `/readyz` check must return HTTP 200 to Railway's internal healthcheck before the deployment becomes active.

The public guide covers operator setup, backups, upgrades, networking limits, and troubleshooting. Review the template's live Share link before updating its links in all four root README locales, the homepage, and the deployment guide.
