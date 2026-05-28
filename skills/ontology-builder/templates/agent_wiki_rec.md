# Agent Wiki Recommendation

## What It Is

A compounding knowledge system where an AI agent captures, organizes, and retrieves institutional knowledge. Team decisions, corrections, research notes, and onboarding material — all searchable and growing over time.

## When This Was Recommended

You want to capture institutional knowledge that compounds — decisions made, lessons learned, domain expertise that currently lives in people's heads.

## What Gets Built

1. **Stage structure** — organized Markdown files on a Snowflake stage
2. **Cortex Search service** — semantic search over the wiki content
3. **Cortex Agent** — reads and writes to the wiki, answers questions from it
4. **Compounding loop** — every conversation makes the wiki smarter

## Architecture

```
@WIKI_STAGE/
├── topics/          # One file per concept/person/project
├── decisions/       # Append-only decision log
├── inbox/           # Raw captures (transcripts, notes)
└── _index.md        # Auto-generated map

Cortex Search → indexes all .md files for semantic retrieval
Cortex Agent → reads wiki for context, writes new topics when knowledge is captured
```

## Snowflake Features Used

- Internal Stage (file storage)
- Cortex Search Service (semantic indexing + retrieval)
- Cortex Agents (read/write agent that maintains the wiki)
- Document AI / AI_PARSE_DOCUMENT (ingesting raw documents into wiki)

## Estimated Time

- Setup: 15-20 minutes (create stage, Cortex Search service)
- Seed: 15 minutes (write first 5-10 topic files from existing knowledge)
- Agent config: 15 minutes (create agent with search + write tools)
- **Total: ~45 minutes for a working wiki with search**

## What "Done" Looks Like

- Ask "what did we decide about X?" and get the answer with context
- New team members search the wiki instead of asking the same questions
- Every meeting/conversation can add to the wiki automatically
- Knowledge grows over time without manual curation

## The Compounding Loop

```
Meeting/conversation → Raw capture to inbox/
    ↓
Agent compaction → Extract entities, update topic files
    ↓
Semantic index → Cortex Search re-indexes
    ↓
Next conversation → Agent retrieves relevant context
    ↓
Better outcomes → More captures → Loop continues
```

## Strengths

- Zero schema cost — start in minutes
- Naturally multimodal (paste anything, LLM extracts)
- Retrieval-friendly (Markdown is exactly what LLMs were trained on)
- Bridges to formal ontology: wiki naturally grows toward structured models

## Limitations

- Not for analytical queries (use Semantic View for that)
- Not for industry-standard codes (use Reference Terminology)
- Requires discipline to avoid drift/duplication
- Governance and access control need explicit attention

## Next Steps After This Layer

- Repeated entities in the wiki get promoted to a Semantic View (graduation)
- High-value relationships get formalized into a Domain Graph
- Wiki becomes the "seed corpus" for more structured ontologies

## Delegation

This routes to the `search-optimization` skill for Cortex Search setup.
