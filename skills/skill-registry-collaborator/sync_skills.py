#!/usr/bin/env python3
"""
Skill Registry Sync — Pushes all local skills (parents + sub-skills) to
SKILL_REGISTRY.PUBLIC.SKILLS as separate rows with PARENT_SKILL_ID.

Idempotent: uses MERGE ON (SKILL_ID, VERSION).
Run: SNOWFLAKE_CONNECTION_NAME=HealthcareDemos python3 sync_skills.py
"""

import os
import json
import uuid
import snowflake.connector

SKILLS_DIR = os.path.expanduser("~/.snowflake/cortex/skills")
CONN_NAME = os.getenv("SNOWFLAKE_CONNECTION_NAME", "HealthcareDemos")

DOMAIN_MAP = {
    'hcls-pharma-genomics': 'genomics',
    'hcls-pharma-dsafety': 'drug-safety',
    'hcls-pharma-lab': 'lab-sciences',
    'hcls-provider-cdata': 'clinical-data',
    'hcls-provider-claims': 'claims-analytics',
    'hcls-provider-imaging': 'imaging',
    'hcls-cross': 'healthcare-platform',
    'ncpdp': 'pharmacy',
    'guppi': 'project-management',
    'build-protocol': 'devops',
    'app-testing': 'devops',
    'sdlc-preflight': 'devops',
    'skill-registry': 'platform',
    'the-bond': 'platform',
    'spcs-': 'devops',
    'synthetic-data': 'data-quality',
    'ontology-stack': 'data-quality',
    'agent-guardrails': 'security',
    'tars-trust': 'governance',
    'clinical-outcome': 'healthcare',
    'snowflake-health': 'healthcare',
}


def get_domain(skill_id):
    for prefix, domain in DOMAIN_MAP.items():
        if skill_id.startswith(prefix):
            return domain
    return 'healthcare'


def parse_skill_md(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    fm = {}
    body = content

    if content.startswith('---'):
        parts = content.split('---', 2)
        if len(parts) >= 3:
            import yaml
            try:
                fm = yaml.safe_load(parts[1]) or {}
            except Exception:
                fm = {}
            body = parts[2].strip()

    return fm, body


def discover_references(skill_dir):
    refs_dir = os.path.join(skill_dir, 'references')
    if not os.path.isdir(refs_dir):
        return {}
    refs = {}
    for fname in sorted(os.listdir(refs_dir)):
        fpath = os.path.join(refs_dir, fname)
        if os.path.isfile(fpath):
            try:
                with open(fpath, 'r', encoding='utf-8') as f:
                    refs[fname] = f.read()
            except Exception:
                refs[fname] = "(binary or unreadable)"
    return refs


def discover_skills(base_dir):
    """Walk the skills directory and yield (skill_id, parent_skill_id, skill_dir, depth)."""
    for entry in sorted(os.listdir(base_dir)):
        top_dir = os.path.join(base_dir, entry)
        skill_md = os.path.join(top_dir, 'SKILL.md')
        if not os.path.isfile(skill_md):
            continue

        yield (entry, None, top_dir)

        for sub_entry in sorted(os.listdir(top_dir)):
            sub_dir = os.path.join(top_dir, sub_entry)
            sub_skill_md = os.path.join(sub_dir, 'SKILL.md')
            if os.path.isdir(sub_dir) and os.path.isfile(sub_skill_md):
                sub_skill_id = f"{entry}/{sub_entry}"
                yield (sub_skill_id, entry, sub_dir)

                for deep_entry in sorted(os.listdir(sub_dir)):
                    deep_dir = os.path.join(sub_dir, deep_entry)
                    deep_skill_md = os.path.join(deep_dir, 'SKILL.md')
                    if os.path.isdir(deep_dir) and os.path.isfile(deep_skill_md):
                        deep_skill_id = f"{entry}/{sub_entry}/{deep_entry}"
                        yield (deep_skill_id, sub_skill_id, deep_dir)


def main():
    conn = snowflake.connector.connect(connection_name=CONN_NAME)
    cur = conn.cursor()

    existing = {}
    cur.execute("SELECT SKILL_ID, SKILL_UUID FROM SKILL_REGISTRY.PUBLIC.SKILLS")
    for row in cur.fetchall():
        existing[row[0]] = row[1]

    inserted = 0
    updated = 0

    for skill_id, parent_id, skill_dir in discover_skills(SKILLS_DIR):
        skill_md_path = os.path.join(skill_dir, 'SKILL.md')
        fm, body = parse_skill_md(skill_md_path)

        name = fm.get('name', skill_id.split('/')[-1])
        description = fm.get('description', '')
        skill_name = name.replace('-', ' ').title() if '/' not in skill_id else name

        top_level_id = skill_id.split('/')[0]
        domain = get_domain(top_level_id)

        references = discover_references(skill_dir)

        skill_content = {"markdown": body}
        if references:
            skill_content["references"] = references

        has_hero = os.path.isfile(os.path.join(skill_dir, 'hero.html'))

        metadata = {
            "local_path": skill_dir,
            "has_hero": has_hero,
            "has_references": bool(references),
            "reference_files": list(references.keys()) if references else [],
        }

        skill_content_json = json.dumps(skill_content)
        metadata_json = json.dumps(metadata)

        skill_uuid = existing.get(skill_id, str(uuid.uuid4()))

        sql = """
MERGE INTO SKILL_REGISTRY.PUBLIC.SKILLS t
USING (SELECT %s AS sid, '1.0.0' AS ver) s
ON t.SKILL_ID = s.sid AND t.VERSION = s.ver
WHEN MATCHED THEN UPDATE SET
    SKILL_NAME = %s,
    DESCRIPTION = %s,
    DOMAIN = %s,
    SKILL_CONTENT = PARSE_JSON(%s),
    METADATA = PARSE_JSON(%s),
    PARENT_SKILL_ID = %s,
    UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
    (SKILL_ID, VERSION, SKILL_NAME, AUTHOR, DOMAIN, DESCRIPTION, SKILL_CONTENT, METADATA, PARENT_SKILL_ID, SKILL_UUID, CREATED_AT, UPDATED_AT)
VALUES
    (%s, '1.0.0', %s, 'CoCo + Todd Crosslin', %s, %s, PARSE_JSON(%s), PARSE_JSON(%s), %s, %s, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP())
"""
        cur.execute(sql, (
            skill_id, skill_name, description, domain, skill_content_json, metadata_json, parent_id,
            skill_id, skill_name, domain, description, skill_content_json, metadata_json, parent_id, skill_uuid,
        ))

        if skill_id in existing:
            updated += 1
            print(f"  ~ {skill_id} (updated)")
        else:
            inserted += 1
            print(f"  + {skill_id} (new)")

    cur.close()
    conn.close()
    print(f"\nDone. Inserted: {inserted}, Updated: {updated}, Total processed: {inserted + updated}")


if __name__ == '__main__':
    main()
