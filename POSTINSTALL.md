The **first account** becomes the instance administrator: open the app and sign in **now**.

* With Cloudron user management, sign in with **Continue with OIDC**. Only Cloudron users can sign
  in; the app's access settings decide who.
* Without it, sign up with email and password, then check under Admin that you are the only user;
  further users join by invitation only.

To connect an MCP client (Claude, Cursor, ...), use `https://$CLOUDRON-APP-DOMAIN/api/mcp`.

Sign-in policy, attachments (S3 storage) and integrations are set in `/app/data/env.sh`
(File Manager); restart the app after editing.
