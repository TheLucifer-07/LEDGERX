import pino from 'pino'
import { readConfig } from './config/env.js'
import { createDatabasePool } from './database/pool.js'
import { createLedgerReadService } from './database/ledger-read-service.js'
import { createSupabaseAccessTokenVerifier } from './security/supabase-jwt.js'
import { createWorkspaceContextHandler } from './security/workspace-context.js'
import { createWorkspaceBootstrapHandler } from './security/workspace-bootstrap.js'
import { createApp } from './app.js'

const config = readConfig()
const logger = pino({ level: config.LOG_LEVEL })
const pool = createDatabasePool(config.DATABASE_URL)
const reads = createLedgerReadService(pool)
const workspaceContext = config.AUTH_DATABASE_URL ? (() => {
  const workspacePool = createDatabasePool(config.AUTH_DATABASE_URL, 'ledgerx-api-workspace')
  const verifyAccessToken = createSupabaseAccessTokenVerifier({
    supabaseUrl: config.SUPABASE_URL,
    jwksUrl: config.SUPABASE_JWKS_URL || undefined,
  })
  return {
    pool: workspacePool,
    handler: createWorkspaceContextHandler({ pool: workspacePool, verifyAccessToken }),
    bootstrapHandler: createWorkspaceBootstrapHandler({ pool: workspacePool, verifyAccessToken }),
  }
})() : null
const app = createApp({ pool, reads, logger, allowedOrigins: config.FRONTEND_ORIGINS, workspaceContext })
const server = app.listen(config.PORT, config.HOST, () => {
  logger.info({ host: config.HOST, port: config.PORT }, 'LedgerX API listening')
})

let closing = false
async function shutdown(signal) {
  if (closing) return
  closing = true
  logger.info({ signal }, 'shutting down')
  const timeout = setTimeout(() => {
    logger.error('shutdown timed out')
    process.exitCode = 1
    server.closeAllConnections()
  }, 10_000)
  timeout.unref()
  server.close(async (error) => {
    if (error) logger.error({ err: error }, 'HTTP server close failed')
    try {
      await pool.end()
      await workspaceContext?.pool.end()
    } catch (poolError) {
      logger.error({ err: poolError }, 'PostgreSQL pool close failed')
      process.exitCode = 1
    }
    clearTimeout(timeout)
    process.exit(process.exitCode ?? 0)
  })
}

process.on('SIGTERM', () => void shutdown('SIGTERM'))
process.on('SIGINT', () => void shutdown('SIGINT'))

process.on('unhandledRejection', (error) => {
  logger.fatal({ err: error }, 'unhandled rejection')
  process.exitCode = 1
  void shutdown('unhandledRejection')
})
