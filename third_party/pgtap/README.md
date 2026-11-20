# pgTAP 1.3.4 (vendored)

Unit-testing framework for PostgreSQL — https://pgtap.org, PostgreSQL-style license (see LICENSE).

`pgtap-1.3.4.sql` is `sql/pgtap.sql.in` from the upstream v1.3.4 tag after the substitution upstream's Makefile performs
for PostgreSQL >= 10 (no compatibility patches apply):

    sed -e 's,MODULE_PATHNAME,pgtap,g' -e 's,__OS__,linux,g' -e 's,__VERSION__,1.3,g' sql/pgtap.sql.in > pgtap-1.3.4.sql

It is installed with plain `psql -f` into schema `tap` of the TEST database only (never into the application schema),
so no PGXS, `pg_config` or OS package is required. Verified against PostgreSQL 17.5.
