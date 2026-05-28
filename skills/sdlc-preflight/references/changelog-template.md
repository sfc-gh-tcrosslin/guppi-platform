# CHANGELOG Template

Standard changelog format for all CoCo healthcare portfolio repos. Follows [Keep a Changelog](https://keepachangelog.com/) conventions.

## Template

```markdown
# Changelog

All notable changes to this project are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)

## [Unreleased]

### Added
- {New features not yet in a release}

## [{Version}] - {YYYY-MM-DD}

### Added
- {New features}

### Changed
- {Modifications to existing features}

### Fixed
- {Bug fixes}

### Removed
- {Removed features}

### Security
- {Security-related changes}
```

## Rules

1. **Newest first**: Latest version at the top
2. **Version format**: Use the same version identifiers as your deployment (V1_6, v2.0, etc.)
3. **Date format**: YYYY-MM-DD (ISO 8601)
4. **Categories**: Only include categories that have entries (don't list empty categories)
5. **Unreleased section**: Always present at top for tracking in-progress work
6. **Link to commits**: Each version entry should note the git commit hash if available

## Generation

To auto-generate from git log:

```bash
git log --pretty=format:"- %s (%h, %ad)" --date=short
```

Group by version tags or by date ranges matching deployment sessions.
