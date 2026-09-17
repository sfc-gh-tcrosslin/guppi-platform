-- =============================================================================
-- guppi-platform v3.24.0 -- RSI Engine Seed 04: Git commit-loop (OPTIONAL)
-- =============================================================================
-- The Tier-3 "open a PR for human merge" layer of the RSI story. SKIP THIS FILE
-- to run the engine propose-only. Requires the git infra TEMPLATES below (edit
-- the org + set the real token out-of-band -- NEVER commit a token) plus
-- 02_prereqs.sql already applied. RUN AS ACCOUNTADMIN (integrations are
-- admin-gated), then the two git procs.
--
-- Safe to re-run.
-- =============================================================================

USE DATABASE GUPPI_RSI_ENGINE;
USE SCHEMA CORE;

-- 1) Egress rule to GitHub. Adjust hosts for GitHub Enterprise if needed.
CREATE NETWORK RULE IF NOT EXISTS GUPPI_RSI_ENGINE.CORE.GITHUB_API_EGRESS
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('api.github.com:443', 'github.com:443')
  COMMENT = 'RSI git commit-loop egress to GitHub.';

-- 2) TEMPLATE ONLY -- replace the placeholder with your own fine-grained PAT
--    out-of-band (manual ALTER SECRET or a separate untracked script).
--    DO NOT commit a real token.
CREATE SECRET IF NOT EXISTS GUPPI_RSI_ENGINE.CORE.GITHUB_TOKEN
  TYPE = GENERIC_STRING
  SECRET_STRING = 'REPLACE_WITH_GITHUB_FINE_GRAINED_PAT'
  COMMENT = 'GitHub fine-grained PAT for the RSI commit-loop. Set the real value out-of-band; never commit it.';

-- 3) Snowflake Git access. Point the prefix at YOUR repo/org.
CREATE OR REPLACE API INTEGRATION GUPPI_GIT_API_INTEGRATION
  API_PROVIDER = GIT_HTTPS_API
  API_ALLOWED_PREFIXES = ('https://github.com/<your-github-org>/')
  ALLOWED_AUTHENTICATION_SECRETS = (GUPPI_RSI_ENGINE.CORE.GITHUB_TOKEN)
  ENABLED = TRUE
  COMMENT = 'RSI commit-loop: Snowflake Git access to your target repo.';

-- 4) External access integration the git procs attach at checkpoint.
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION GUPPI_GITHUB_EAI
  ALLOWED_NETWORK_RULES = (GUPPI_RSI_ENGINE.CORE.GITHUB_API_EGRESS)
  ALLOWED_AUTHENTICATION_SECRETS = (GUPPI_RSI_ENGINE.CORE.GITHUB_TOKEN)
  ENABLED = TRUE
  COMMENT = 'RSI headless git write path: egress to api.github.com. Auth secret attached at checkpoint.';

GRANT USAGE ON INTEGRATION GUPPI_GIT_API_INTEGRATION TO ROLE RSI_ENGINE;
GRANT USAGE ON INTEGRATION GUPPI_GITHUB_EAI TO ROLE RSI_ENGINE;
GRANT USAGE ON SECRET GUPPI_RSI_ENGINE.CORE.GITHUB_TOKEN TO ROLE RSI_ENGINE;
GRANT USAGE ON NETWORK RULE GUPPI_RSI_ENGINE.CORE.GITHUB_API_EGRESS TO ROLE RSI_ENGINE;

-- ---------------------------------------------------------------------------
-- The two git procs (hard-depend on GUPPI_GITHUB_EAI + GITHUB_TOKEN above).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE "RSI_GIT_PUSH"("P_TARGET" VARCHAR, "P_RUN_ID" VARCHAR, "P_CONTENT" VARCHAR, "P_MESSAGE" VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python','requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (GUPPI_GITHUB_EAI)
SECRETS = ('gh'=GUPPI_RSI_ENGINE.CORE.GITHUB_TOKEN)
COMMENT='RSI-4 Tier-2 safe push: guard -> ensure branch rsi/<run_id> -> Contents-API PUT -> open PR. NEVER writes the default branch. Target-agnostic (repo coords from RSI_TARGET_PROFILE).'
EXECUTE AS OWNER
AS '
import _snowflake, requests, base64, json
ALLOWED_OWNERS = {''sfc-gh-tcrosslin''}
API=''https://api.github.com''
def _hdr(tok):
    return {''Authorization'':''Bearer ''+tok,''Accept'':''application/vnd.github+json'',''X-GitHub-Api-Version'':''2022-11-28'',''User-Agent'':''guppi-rsi''}
def run(session, p_target, p_run_id, p_content, p_message):
    # 1. profile repo coords
    row = session.sql("SELECT PROFILE:repo FROM GUPPI_RSI_ENGINE.CORE.RSI_TARGET_PROFILE WHERE TARGET=?", params=[p_target]).collect()
    if not row or row[0][0] is None:
        return {''ok'':False,''reason'':''no repo coords in profile for target ''+str(p_target)}
    repo = json.loads(row[0][0]) if isinstance(row[0][0], str) else row[0][0]
    owner=repo[''owner'']; name=repo[''name'']; base=repo.get(''default_branch'',''main''); path=repo[''artifact_path'']
    # 2. namespace guard (defense in depth beyond token scope)
    if owner not in ALLOWED_OWNERS:
        return {''ok'':False,''reason'':''blocked: owner %s outside allowed namespace'' % owner}
    # 3. content guard
    g = session.sql("CALL GUPPI_RSI_ENGINE.CORE.RSI_GUARD_CONTENT(?,?,?)", params=[p_target, path, p_content]).collect()[0][0]
    g = json.loads(g) if isinstance(g,str) else g
    if not g.get(''ok''):
        return {''ok'':False,''reason'':''guard ''+g.get(''reason'',''blocked''),''hits'':g.get(''hits'')}
    # 4. github calls
    up=_snowflake.get_username_password(''gh''); tok=up.password; H=_hdr(tok)
    branch=''rsi/''+str(p_run_id)
    rbase=''%s/repos/%s/%s'' % (API, owner, name)
    r=requests.get(rbase+''/git/ref/heads/''+base, headers=H, timeout=30)
    if r.status_code!=200: return {''ok'':False,''reason'':''base ref %s -> %s'' % (base, r.status_code),''body'':r.text[:300]}
    base_sha=r.json()[''object''][''sha'']
    # ensure branch (create if missing)
    rb=requests.get(rbase+''/git/ref/heads/''+branch, headers=H, timeout=30)
    if rb.status_code==404:
        cr=requests.post(rbase+''/git/refs'', headers=H, json={''ref'':''refs/heads/''+branch,''sha'':base_sha}, timeout=30)
        if cr.status_code not in (200,201): return {''ok'':False,''reason'':''create branch -> %s''%cr.status_code,''body'':cr.text[:300]}
    # current file sha on branch (for update)
    rf=requests.get(rbase+''/contents/''+path+''?ref=''+branch, headers=H, timeout=30)
    fsha = rf.json().get(''sha'') if rf.status_code==200 else None
    payload={''message'':p_message or (''RSI %s: update %s'' % (p_run_id, path)),''content'':base64.b64encode((p_content or '''').encode()).decode(),''branch'':branch}
    if fsha: payload[''sha'']=fsha
    pu=requests.put(rbase+''/contents/''+path, headers=H, json=payload, timeout=30)
    if pu.status_code not in (200,201): return {''ok'':False,''reason'':''PUT contents -> %s''%pu.status_code,''body'':pu.text[:300]}
    commit_sha=pu.json()[''commit''][''sha'']
    # open PR (skip if one already open for this head)
    ex=requests.get(rbase+''/pulls?head=%s:%s&state=open'' % (owner, branch), headers=H, timeout=30)
    if ex.status_code==200 and ex.json():
        pr_url=ex.json()[0][''html_url'']
    else:
        pr=requests.post(rbase+''/pulls'', headers=H, json={''title'':''RSI candidate %s''%p_run_id,''head'':branch,''base'':base,''body'':(p_message or ''Automated RSI candidate. Human review + merge required (Tier-3).'')}, timeout=30)
        pr_url = pr.json().get(''html_url'') if pr.status_code in (200,201) else (''PR create -> %s: %s''%(pr.status_code, pr.text[:200]))
    return {''ok'':True,''target'':p_target,''branch'':branch,''base'':base,''commit_sha'':commit_sha,''pr_url'':pr_url,''path'':path}
';

CREATE OR REPLACE PROCEDURE "RSI_GIT_DELETE_BRANCH"("P_TARGET" VARCHAR, "P_BRANCH" VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python','requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (GUPPI_GITHUB_EAI)
SECRETS = ('gh'=GUPPI_RSI_ENGINE.CORE.GITHUB_TOKEN)
COMMENT='Delete a branch (closes its PR). Dual-use: throwaway cleanup + RSI-6 rollback. Refuses to delete the default branch.'
EXECUTE AS OWNER
AS '
import _snowflake, requests, json
ALLOWED_OWNERS={''sfc-gh-tcrosslin''}
def run(session, p_target, p_branch):
    row=session.sql("SELECT PROFILE:repo FROM GUPPI_RSI_ENGINE.CORE.RSI_TARGET_PROFILE WHERE TARGET=?", params=[p_target]).collect()
    repo=json.loads(row[0][0]) if isinstance(row[0][0],str) else row[0][0]
    owner=repo[''owner'']; name=repo[''name'']; base=repo.get(''default_branch'',''main'')
    if owner not in ALLOWED_OWNERS: return {''ok'':False,''reason'':''owner outside namespace''}
    if p_branch==base: return {''ok'':False,''reason'':''refusing to delete default branch''}
    tok=_snowflake.get_username_password(''gh'').password
    H={''Authorization'':''Bearer ''+tok,''Accept'':''application/vnd.github+json'',''X-GitHub-Api-Version'':''2022-11-28'',''User-Agent'':''guppi-rsi''}
    r=requests.delete(''https://api.github.com/repos/%s/%s/git/refs/heads/%s''%(owner,name,p_branch), headers=H, timeout=30)
    return {''ok'': r.status_code in (204,), ''status'': r.status_code, ''branch'': p_branch}
';

