Use the `db-reader` agent for read-only database queries:

$ARGUMENTS

IMPORTANT: This agent is restricted to SELECT queries only. INSERT, UPDATE, DELETE, DROP, CREATE, ALTER, TRUNCATE, REPLACE, and MERGE are blocked by a PreToolUse hook. For write operations, use the `data-scientist` agent instead.
