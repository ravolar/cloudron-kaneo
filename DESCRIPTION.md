This is an **unofficial community package**, not affiliated with or supported by the Kaneo authors.

Kaneo is a clean, fast, open source project management tool: workspaces, projects, kanban and list
views, tasks with labels, assignees, due dates, comments, time tracking and task relations, with
real-time updates for everyone on the board.

### Features

* **Built-in MCP server** at `/api/mcp`: connect Claude, Cursor and other MCP clients over OAuth and
  let them read and manage your projects and tasks with your permissions
* **Sign in with Cloudron**: users log in with their Cloudron account (optional)
* Workspaces with members, roles and invitations by email
* Kanban and list views, custom fields, workflow rules, search and notifications
* Integrations: GitHub, GitLab, Gitea, Slack, Discord, Telegram, Mattermost and webhooks
* REST API with API keys, plus a command-line client

### This package

* Runs Kaneo's official build; the only change is a small security fix to the MCP `whoami` tool,
  which upstream lets return the caller's session token. PostgreSQL and outgoing email are
  provided by Cloudron
* Attachments need S3-compatible object storage (optional)
