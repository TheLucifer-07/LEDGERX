# Migration 0017 — bootstrap retry visibility

Adds a narrow workspace SELECT policy used while the first-workspace bootstrap
function searches for an existing owner workspace. It requires the transaction
local provisioning flag and an active owner membership for the verified
internal user. The workspace membership table has its own provisioning policy
with the same user restriction. This keeps the retry lookup working under
forced RLS without granting `ledgerx_api` direct reads from workspace tables.

This additive migration corrects an isolated SQL test failure discovered after
0016. Validate the repeat-bootstrap assertion, API role grants, and tenant
isolation on the disposable PostgreSQL 17 cluster before applying it locally.
