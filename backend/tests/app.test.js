import pino from 'pino'
import request from 'supertest'
import { describe, expect, it, vi } from 'vitest'
import { createApp } from '../src/app.js'

function setup({ ready = true } = {}) {
  const pool = { query: vi.fn(async () => {
    if (!ready) throw new Error('database is unavailable')
    return { rows: [{ '?column?': 1 }], rowCount: 1 }
  }) }
  const reads = {
    health: vi.fn(async () => ({ status: 'ok' })),
    summary: vi.fn(async ({ from, to }) => ({ integrity_finding_count: 0, date_range: { from, to } })),
  }
  const logger = pino({ level: 'silent' })
  return { app: createApp({ pool, reads, logger, allowedOrigins: ['http://localhost:5173'] }), pool, reads }
}

describe('health and read-only API shell', () => {
  it('reports liveness without checking dependencies', async () => {
    const { app, pool } = setup({ ready: false })
    const response = await request(app).get('/health/live').expect(200)
    expect(response.body).toEqual({ status: 'live' })
    expect(pool.query).not.toHaveBeenCalled()
  })

  it('reports readiness only after PostgreSQL responds', async () => {
    const { app } = setup()
    await request(app).get('/health/ready').expect(200, { status: 'ready' })
  })

  it('returns a bounded starting response when PostgreSQL is unavailable', async () => {
    const { app } = setup({ ready: false })
    await request(app).get('/health/ready').expect(503, { status: 'starting', error: 'dependency_unavailable' })
  })

  it('keeps the legacy API health route free of database details', async () => {
    const { app } = setup()
    await request(app).get('/api/v1/health').expect(200, { status: 'ok' })
  })

  it('passes validated date filters to the real read service', async () => {
    const { app, reads } = setup()
    await request(app).get('/api/v1/dashboard/summary?from=2026-01-01&to=2026-01-31')
      .expect(200)
      .expect(({ body }) => expect(body.integrity_finding_count).toBe(0))
    expect(reads.summary).toHaveBeenCalledWith({ from: '2026-01-01', to: '2026-01-31' })
  })

  it('rejects malformed dates and invalid pagination', async () => {
    const { app } = setup()
    await request(app).get('/api/v1/dashboard/summary?from=2026-02-31').expect(400)
    await request(app).get('/api/v1/transactions?page=-1').expect(400)
  })

  it('does not expose financial mutation routes', async () => {
    const { app } = setup()
    await request(app).post('/api/v1/transactions').send({ amount: 1 }).expect(405)
  })

  it('blocks browser origins outside the explicit allowlist', async () => {
    const { app } = setup()
    const response = await request(app).get('/api/v1/health').set('Origin', 'https://untrusted.example').expect(403)
    expect(response.headers['access-control-allow-origin']).toBeUndefined()
  })

  it('returns CORS permission only for an allowlisted origin', async () => {
    const { app } = setup()
    const response = await request(app).get('/api/v1/health').set('Origin', 'http://localhost:5173').expect(200)
    expect(response.headers['access-control-allow-origin']).toBe('http://localhost:5173')
  })
})
