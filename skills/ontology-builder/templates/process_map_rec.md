# Process Map / Operational Ontology Recommendation

## What It Is

A model of your business objects, their relationships, and the ACTIONS that can happen to them. Unlike a semantic view (which describes), an operational ontology DOES things — it triggers workflows, enforces rules, and drives automation.

## When This Was Recommended

You said that when data changes, real-world actions need to happen. Approvals, alerts, dispatches, blocks, escalations.

## What Gets Built

1. **Object-Link-Action schema** — tables representing entities, their connections, and available operations
2. **Stored procedures** — the actual logic for each action
3. **Cortex Agent** — an autonomous agent that monitors state and executes actions at the appropriate autonomy level
4. **Tasks/Alerts** — scheduled checks that trigger the agent or notify humans

## Pattern (Object-Link-Action)

```
OBJECTS: What exists in your domain (Patient, Claim, Order, Trade, Asset)
LINKS:   How they connect (Patient → submits → Claim, Order → contains → Item)
ACTIONS: What can happen (approveClaim, rejectOrder, escalateAlert, dispatchTech)
```

## Snowflake Features Used

- Tables (object and link storage)
- Stored Procedures (action implementations)
- Cortex Agents (autonomous monitoring + execution)
- Tasks (scheduled checks)
- Alerts (condition-based triggers)
- Notification Integrations (Slack/email/webhook for human escalation)

## Estimated Time

- Discovery: 20-30 minutes (map objects, links, and actions)
- Build schema: 30 minutes (CREATE tables, relationships)
- Build first action: 30-60 minutes (procedure + agent spec)
- **Total: 2-4 hours for a working first action**

## What "Done" Looks Like

- A specific business action fires automatically when conditions are met
- Human gets notified only when escalation is needed
- Full audit trail of every action taken
- Graduated autonomy: routine auto-handles, anomalies escalate

## Example (Claims Adjudication)

```
Objects: Member, Claim, Drug, Pharmacy, Prescriber
Links: Member → submits → Claim, Claim → contains → Drug
Actions: adjudicate(claim_id), override(claim_id, reason), reverse(claim_id)
Agent: Seymour — monitors pricing, formulary, health; acts at assigned level
```

## Next Steps After This Layer

- Add Semantic View for reporting on operational outcomes
- Add Domain Graph to trace relationships across the operational model
- Expand action catalog as new workflows are identified
