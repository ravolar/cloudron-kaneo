The **first account** that signs up becomes the instance administrator: open the app and create it now.

* With Cloudron user management, sign in with **Continue with OIDC**; new users then join with their
  Cloudron account or an invitation.
* Without it, sign up with email and password; further users join by invitation only.

To connect an MCP client (Claude, Cursor, ...), use `https://$CLOUDRON-APP-DOMAIN/api/mcp`.

Sign-up policy, attachments (S3 storage) and integrations are set in `/app/data/env.sh`
(File Manager); restart the app after editing.
