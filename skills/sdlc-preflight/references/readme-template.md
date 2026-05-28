# README Template

Standard README structure for all CoCo healthcare portfolio repos. Every section below is **required** unless marked optional.

## Template

```markdown
# {Project Name}

{One-sentence description of what this project does.}

**Multi-cloud** · **{Input formats}** → **{Output formats}** · Your data never leaves your account

## Overview

{2-3 paragraph description covering:}
- What problem this solves
- Key design decisions
- What makes this approach unique

### What {Dependency} Provides vs. What This App Builds

| Component | Source | Notes |
|-----------|--------|-------|
| {component} | {source} | {notes} |

> **Important**: {Any critical distinctions about dependencies vs original work.}

## Architecture

```
{ASCII diagram or structured description of data flow}
```

## Features

{Bulleted list of key capabilities, organized by category if >10 items}

### {Category 1}
- Feature A
- Feature B

### {Category 2}
- Feature C

## Output Tables/Artifacts

| Table/Artifact | Source | Description |
|---------------|--------|-------------|
| `{name}` | {source} | {description} |

## Installation

### Prerequisites
- {Required roles, warehouses, etc.}

### From Snowflake Marketplace (if applicable)
1. Search for **"{App Name}"**
2. Click **Get**
3. Grant privileges

### Manual Deployment
```sql
{Deployment SQL}
```

## Usage

### Quick Start
{Minimal steps to get running}

### Configuration
{Configuration options}

### Running
{How to execute, with code examples}

### Programmatic Access
```sql
{SQL/Python examples}
```

## Testing

{Test approach and how to run tests}

```bash
python tests/test_{domain}.py             # Level 1 (smoke)
python tests/test_{domain}.py --level 2   # Level 2 (validate)
python tests/test_{domain}.py --level 3   # Level 3 (full scale)
```

## Version History

| Version | Date | Changes |
|---------|------|---------|
| V1.0 | YYYY-MM-DD | Initial release |

Or: See [CHANGELOG.md](CHANGELOG.md) for detailed version history.

## Cloud Support

| Cloud | Status |
|-------|--------|
| AWS   | ✅     |
| Azure | ✅     |
| GCP   | ✅     |

## Application Roles (if Native App)

| Role | Access Level |
|------|-------------|
| `app_admin` | Full access |
| `app_user` | Read-only |

## CoCo Skill (if applicable)

This project includes a CoCo skill at `skill/` for guided builds:
- **Skill name**: `{skill-name}`
- **Install**: Copy `skill/` to `~/.snowflake/cortex/skills/{skill-name}/`
- **Use**: `${skill-name}` in CoCo

## Credits & Acknowledgments

- **[{Dependency}]({url})** ({license}) — {what it provides}

## License

{License type} — See [LICENSE](LICENSE) for details.

## Project Structure

```
{repo-name}/
├── manifest.yml
├── README.md
├── CHANGELOG.md
├── scripts/
│   └── ...
├── streamlit/
│   └── ...
├── skill/
│   └── SKILL.md
└── tests/
    └── ...
```
```

## Validation Rules

When checking a README against this template:

1. **Title**: Must match what the app actually does (not an old name)
2. **Architecture**: Must show current data flow (all input formats, all output formats)
3. **Features/Tables**: Counts must match actual code (e.g., if code has 23 mappers, README must reflect that)
4. **Code examples**: Must use current proc names and parameter signatures
5. **Project structure**: Must match actual `ls` output (no phantom directories)
6. **Version history**: Must include latest deployed version
7. **Skill section**: Must reference current skill name (not old names)
