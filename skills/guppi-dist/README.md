# GUPPI Distribution Bundle

## What's Included

```
guppi-dist/
├── SKILL.md              # Core GUPPI skill (Bond-free, native-only tracker)
├── tars/
│   └── SKILL.md          # TARS trust auditor (self-contained)
├── render_guppi.py       # HTML viewer generator
├── setup.sql             # One-shot DB creation script
└── README.md             # Getting started guide
```

## Quick Start

1. Run `setup.sql` in your Snowflake account (creates GUPPI database + tables)
2. Copy `SKILL.md` to `~/.snowflake/cortex/skills/guppi/SKILL.md`
3. Copy `tars/SKILL.md` to `~/.snowflake/cortex/skills/tars-trust-auditor/SKILL.md`
4. Start talking: "create a story for user authentication"

## What This Is

GUPPI is a headless, AI-native SDLC platform that runs entirely in Snowflake.

- **No webapp.** The database IS the application.
- **No forms.** You talk to it — "create a story", "log an incident", "show backlog".
- **No infrastructure.** Just Snowflake tables + a CoCo skill.
- **Auditable by default.** Every action is tracked.

## What's NOT Included

- Bond (federated memory layer — separate product)
- External tracker integrations (Jira MCP, ServiceNow MCP)
- Enterprise Build Profile (session orchestration layer)

This is the core: plan, track, verify, operate. Everything you need to run lean.
