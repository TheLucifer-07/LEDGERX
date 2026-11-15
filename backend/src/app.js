import cors from 'cors'
import express from 'express'
import { rateLimit } from 'express-rate-limit'
import helmet from 'helmet'
import pinoHttp from 'pino-http'
import { createV1Router } from './routes/v1.js'
import { HttpError } from './utils/http-error.js'

export function createApp({ pool, reads, logger, allowedOrigins, workspaceContext }) {
  const app = express()
  const originSet = new Set(allowedOrigins)
  const requestLogger = pinoHttp({
    logger,
    serializers: {
      req: (request) => ({ id: request.id, method: request.method, url: request.url.split('?')[0], remoteAddress: request.remoteAddress }),
      res: (response) => ({ statusCode: response.statusCode }),
    },
  })

  app.disable('x-powered-by')
  app.use(helmet())
  app.use(requestLogger)
  app.use(cors({
    credentials: true,
    methods: ['GET', 'HEAD', 'POST', 'OPTIONS'],
    allowedHeaders: ['Accept', 'Content-Type', 'Authorization', 'X-LedgerX-Workspace-ID'],
    origin(origin, callback) {
      if (!origin || originSet.has(origin)) return callback(null, true)
      return callback(new HttpError(403, 'origin_not_allowed', 'This browser origin is not allowed.'))
    },
  }))
  app.use(express.json({ limit: '100kb', strict: true }))
  app.use('/api', rateLimit({ windowMs: 60_000, limit: 120, standardHeaders: 'draft-8', legacyHeaders: false }))
  app.use((_request, response, next) => {
    response.set('Cache-Control', 'no-store')
    next()
  })

  app.get('/health/live', (_request, response) => response.json({ status: 'live' }))
  app.get('/health/ready', async (_request, response) => {
    try {
      await Promise.all([pool.query('SELECT 1'), ...(workspaceContext ? [workspaceContext.pool.query('SELECT 1')] : [])])
      response.json({ status: 'ready' })
    } catch (error) {
      logger.error({ err: error }, 'readiness check failed')
      response.status(503).json({ status: 'starting', error: 'dependency_unavailable' })
    }
  })
  app.use('/api/v1', createV1Router(reads, {
    workspaceContext: workspaceContext?.handler,
    workspaceBootstrap: workspaceContext?.bootstrapHandler,
  }))

  app.use((_request, _response, next) => next(new HttpError(404, 'not_found', 'The requested route was not found.')))
  app.use((error, request, response, next) => {
    if (response.headersSent) return next(error)
    const status = error instanceof HttpError ? error.status : error.status === 413 ? 413 : 500
    if (status >= 500) logger.error({ err: error, requestId: request.id }, 'request failed')
    response.status(status).json({
      error: error instanceof HttpError ? error.code : status === 413 ? 'request_too_large' : 'internal_server_error',
      message: error instanceof HttpError ? error.message : status === 413 ? 'Request body is too large.' : 'An unexpected error occurred.',
    })
  })
  return app
}
