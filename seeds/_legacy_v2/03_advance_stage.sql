-- GuppiWheel ADVANCE_STAGE Stored Procedure
-- Universal server-side gate for stage transitions.
-- Evaluates all applicable rules, blocks or warns, logs violations.
-- Run AFTER 01_schema.sql and 02_rules.sql

CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.ADVANCE_STAGE(
    P_ARTIFACT_ID VARCHAR,
    P_TARGET_STAGE VARCHAR,
    P_OVERRIDE_REASON VARCHAR DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json

def run(session, p_artifact_id, p_target_stage, p_override_reason):
    # Look up the artifact
    art = session.sql(f"""
        SELECT TYPE, STAGE FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = '{p_artifact_id}'
    """).collect()
    
    if not art:
        return json.dumps({"success": False, "error": f"Artifact not found: {p_artifact_id}"})
    
    current_type = art[0]['TYPE']
    current_stage = art[0]['STAGE']
    
    if current_stage == p_target_stage:
        return json.dumps({"success": False, "error": f"Already at stage: {p_target_stage}"})
    
    # Get applicable rules
    rules = session.sql(f"""
        SELECT RULE_ID, CONDITION_SQL, ENFORCEMENT, OVERRIDABLE, MESSAGE
        FROM GUPPIWHEEL.PUBLIC.RULES
        WHERE ENABLED = TRUE
          AND RULE_TYPE = 'stage_transition'
          AND (APPLIES_TO_TYPE = 'ALL' OR APPLIES_TO_TYPE = '{current_type}')
          AND (FROM_STAGE IS NULL OR FROM_STAGE = '{current_stage}')
          AND (TO_STAGE IS NULL OR TO_STAGE = '{p_target_stage}')
    """).collect()
    
    blocked = False
    blockers = []
    warnings = []
    overrides_used = []
    
    for rule in rules:
        rule_id = rule['RULE_ID']
        condition = rule['CONDITION_SQL']
        enforcement = rule['ENFORCEMENT']
        overridable = rule['OVERRIDABLE']
        message = rule['MESSAGE']
        
        # Evaluate the condition SQL
        eval_sql = f"SELECT ({condition.replace(':artifact_id', chr(39) + p_artifact_id + chr(39))}) AS PASSES"
        try:
            result = session.sql(eval_sql).collect()
            passes = result[0]['PASSES'] if result else False
        except Exception as e:
            passes = False
        
        if not passes:
            if enforcement == 'block':
                if overridable and p_override_reason:
                    overrides_used.append({"rule": rule_id, "message": message, "reason": p_override_reason})
                    session.sql(f"""
                        INSERT INTO GUPPIWHEEL.PUBLIC.VIOLATIONS (RULE_ID, ARTIFACT_ID, STATUS, OVERRIDE_REASON)
                        VALUES ('{rule_id}', '{p_artifact_id}', 'overridden', '{p_override_reason}')
                    """).collect()
                else:
                    blocked = True
                    blockers.append({"rule": rule_id, "message": message, "overridable": overridable})
            else:
                warnings.append({"rule": rule_id, "message": message})
                session.sql(f"""
                    INSERT INTO GUPPIWHEEL.PUBLIC.VIOLATIONS (RULE_ID, ARTIFACT_ID, STATUS)
                    VALUES ('{rule_id}', '{p_artifact_id}', 'open')
                """).collect()
    
    if blocked:
        return json.dumps({
            "success": False, "blocked": True,
            "blockers": blockers, "warnings": warnings,
            "message": "Stage transition BLOCKED. Address blockers before advancing."
        }, indent=2)
    
    # Advance the stage
    session.sql(f"""
        UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS SET STAGE = '{p_target_stage}', UPDATED_AT = CURRENT_TIMESTAMP()
        WHERE ID = '{p_artifact_id}'
    """).collect()
    
    return json.dumps({
        "success": True, "artifact_id": p_artifact_id,
        "from_stage": current_stage, "to_stage": p_target_stage,
        "warnings": warnings, "overrides_used": overrides_used
    }, indent=2)
$$;
