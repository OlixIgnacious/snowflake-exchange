-- AUDIT_INSERT: INSERT-only on AUDIT_LOG, no SELECT (architecture.md RBAC section) -- this role
-- can write an audit trail entry but never read one back, including its own.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

GRANT INSERT ON TABLE AUDIT_LOG TO ROLE AUDIT_INSERT;
