# Railway template

The [Railway deployment guide](https://www.codex-pooler.com/docs/deployment/railway/) is the installation entry point. The template creates one application service and one private PostgreSQL service with persistent storage, generated secrets, automatic migrations, and a public application domain.

This directory maintains [the marketplace overview](marketplace.md). The deployment configuration lives in Railway's template composer. Railway uses that saved configuration when someone deploys the template; no repository manifest is imported or synchronized automatically.

Before publishing a template update, select the intended release image and review the variables, services, networking, and lifecycle settings in the composer. Apply the changes and inspect the saved configuration. Test a fresh deployment from that exact template, including migration failure, recovery, and persistence across application and database restarts. Record the resolved image digest with the acceptance results. A locally uploaded candidate build does not certify a different published image.

Keep the application at one replica with Serverless disabled. Preserve all generated secrets and the PostgreSQL volume when upgrading an existing installation. The application pre-deploy command runs migrations and pricing import; the `/readyz` check must return HTTP 200 to Railway's internal healthcheck before the deployment becomes active.

The public guide covers operator setup, backups, upgrades, networking limits, and troubleshooting. Review the template's live Share link before updating its links in all four root README locales, the homepage, and the deployment guide.
