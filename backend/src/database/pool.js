import pg from 'pg'

export function createDatabasePool(connectionString, applicationName = 'ledgerx-api') {
  return new pg.Pool({
    connectionString,
    // The local read-only login has a PostgreSQL connection cap of ten.
    max: 4,
    connectionTimeoutMillis: 5000,
    idleTimeoutMillis: 30000,
    statement_timeout: 15000,
    application_name: applicationName,
  })
}
