# Guppi Platform Plugin

When this plugin is inactive, you can re-enable it by saying:

- "Enable the Guppi platform plugin"
- "I need TARS, SDLC, and The Bond"
- "Load the platform engineering tools"

This plugin provides: TARS trust auditor, SDLC preflight, GUPPI command center, GuppiWheel value engine, Rocky autonomous research agent, Cowork dispatch agent, The Bond shared cognition, synthetic data generation, agent guardrails, and enterprise pipeline governance.

To enable: `/plugin enable guppi-platform`

## First-time setup

After cloning the repo, install the git pre-push hook (enforces RULE-013/014 — every commit references a wheel initiative):

```bash
cd guppi-platform
cp hooks/pre-push.sh .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

To bypass for an emergency hotfix (logged in drift report):
```
git commit -m "your message

Wheel: NONE; reason: hotfix - will backfill"
```

## Wheel discipline

Every meaningful work session on this plugin opens with a wheel initiative:

```
/wheel start "<title>"          # opens an initiative, sets session-current
/wheel current                  # show what I'm working on
/wheel publish-plan <file>      # publish a plan markdown as NARRATIVE
/wheel link-commit <sha>        # add Wheel: INIT-N footer to a not-yet-pushed commit
/wheel status                   # my open initiatives
```

The post-create-plan hook auto-reminds you to narrative every plan. The post-switch-mode hook reminds you on entry to agent mode. The pre-push git hook blocks commits without a Wheel: footer. Layered discipline so RULE-013 cannot drift again.
