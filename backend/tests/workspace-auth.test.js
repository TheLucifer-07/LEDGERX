import { generateKeyPairSync, sign } from 'node:crypto'
import pino from 'pino'
import request from 'supertest'
import { describe, expect, it, vi } from 'vitest'
import { createApp } from '../src/app.js'
import { createSupabaseAccessTokenVerifier } from '../src/security/supabase-jwt.js'
import { createWorkspaceBootstrapHandler } from '../src/security/workspace-bootstrap.js'
import { createWorkspaceContextHandler } from '../src/security/workspace-context.js'

const supabaseUrl = 'https://ledgerx-test.supabase.co'
const subject = '10000000-0000-4000-8000-000000000001'
const workspaceId = '20000000-0000-4000-8000-000000000001'
const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 })
const jwk = {
  ...publicKey.export({ format: 'jwk' }),
  alg: 'RS256',
  kid: 'ledgerx-test-key',
  use: 'sig',
}

function makeToken(overrides = {}) {
  const now = Math.floor(Date.now() / 1000)
  const header = { alg: 'RS256', kid: jwk.kid, typ: 'JWT' }
  const payload = {
    sub: subject,
    iss: `${supabaseUrl}/auth/v1`,
    aud: 'authenticated',
    role: 'authenticated',
    iat: now,
    exp: now + 300,
    ...overrides,
  }
  const input = `${encodePart(header)}.${encodePart(payload)}`
  const signature = sign('RSA-SHA256', Buffer.from(input), privateKey).toString('base64url')
  return `${input}.${signature}`
}

function encodePart(value) {
  return Buffer.from(JSON.stringify(value)).toString('base64url')
}

function setup({ queryError } = {}) {
  const client = {
    query: vi.fn(async (sql) => {
      if (sql.startsWith('SELECT user_id, membership_role FROM ledger.set_request_context')) {
        if (queryError) throw queryError
        return { rows: [{ user_id: '30000000-0000-4000-8000-000000000001', membership_role: 'owner' }] }
      }
      if (sql.startsWith('SELECT user_id, workspace_id, workspace_type, workspace_name, created')) {
        if (queryError) throw queryError
        return { rows: [{
          user_id: '30000000-0000-4000-8000-000000000001',
          workspace_id: workspaceId,
          workspace_type: 'student',
          workspace_name: 'Ananya Student Ledger',
          created: true,
        }] }
      }
      return { rows: [] }
    }),
    release: vi.fn(),
  }
  const authPool = { connect: vi.fn(async () => client), query: vi.fn(async () => ({ rows: [{ ok: 1 }] })) }
  const pool = { query: vi.fn(async () => ({ rows: [{ ok: 1 }] })) }
  const verifyAccessToken = createSupabaseAccessTokenVerifier({
    supabaseUrl,
    jwks: { keys: [jwk] },
  })
  const workspaceContext = {
    pool: authPool,
    handler: createWorkspaceContextHandler({ pool: authPool, verifyAccessToken }),
    bootstrapHandler: createWorkspaceBootstrapHandler({ pool: authPool, verifyAccessToken }),
  }
  const reads = { health: vi.fn(async () => ({ status: 'ok' })) }
  const app = createApp({
    pool,
    reads,
    logger: pino({ level: 'silent' }),
    allowedOrigins: ['http://localhost:5173'],
    workspaceContext,
  })
  return { app, authPool, client }
}

describe('Supabase-authenticated workspace context', () => {
  it('validates a signed JWT before asking PostgreSQL to confirm membership', async () => {
    const { app, authPool, client } = setup()
    await request(app)
      .get('/api/v1/workspace/context')
      .set('Authorization', `Bearer ${makeToken()}`)
      .set('X-LedgerX-Workspace-ID', workspaceId)
      .expect(200, {
        user_id: '30000000-0000-4000-8000-000000000001',
        workspace_id: workspaceId,
        role: 'owner',
      })

    expect(authPool.connect).toHaveBeenCalledOnce()
    expect(client.query.mock.calls.map(([sql]) => sql)).toEqual([
      'BEGIN READ ONLY',
      'SELECT user_id, membership_role FROM ledger.set_request_context($1::uuid, $2::uuid)',
      'COMMIT',
    ])
    expect(client.query.mock.calls[1][1]).toEqual([subject, workspaceId])
    expect(client.release).toHaveBeenCalledOnce()
  })

  it('bootstraps a first workspace using the verified subject and a write-scoped database transaction', async () => {
    const { app, authPool, client } = setup()
    await request(app)
      .post('/api/v1/workspaces/bootstrap')
      .set('Authorization', `Bearer ${makeToken()}`)
      .send({ workspace_type: 'student', workspace_name: 'Ananya Student Ledger' })
      .expect(201, {
        user_id: '30000000-0000-4000-8000-000000000001',
        workspace: { id: workspaceId, type: 'student', name: 'Ananya Student Ledger' },
        created: true,
      })

    expect(client.query.mock.calls.map(([sql]) => sql)).toEqual([
      'BEGIN READ WRITE',
      'SELECT user_id, workspace_id, workspace_type, workspace_name, created\n           FROM ledger.bootstrap_workspace($1::uuid, $2::text, $3::text)',
      'COMMIT',
    ])
    expect(client.query.mock.calls[1][1]).toEqual([subject, 'student', 'Ananya Student Ledger'])
    expect(authPool.connect).toHaveBeenCalledOnce()
    expect(client.release).toHaveBeenCalledOnce()
  })

  it('rejects invalid workspace input without opening a database transaction', async () => {
    const { app, authPool } = setup()
    await request(app)
      .post('/api/v1/workspaces/bootstrap')
      .set('Authorization', `Bearer ${makeToken()}`)
      .send({ workspace_type: 'unrecognized', workspace_name: '' })
      .expect(400, {
        error: 'invalid_workspace_request',
        message: 'Provide a workspace type and a name between 1 and 120 characters.',
      })
    expect(authPool.connect).not.toHaveBeenCalled()
  })

  it('rolls back and hides database details when workspace creation fails', async () => {
    const { app, authPool, client } = setup({ queryError: new Error('private constraint detail') })
    await request(app)
      .post('/api/v1/workspaces/bootstrap')
      .set('Authorization', `Bearer ${makeToken()}`)
      .send({ workspace_type: 'personal', workspace_name: 'My Ledger' })
      .expect(503, {
        error: 'workspace_bootstrap_unavailable',
        message: 'Workspace setup is temporarily unavailable.',
      })
    expect(client.query.mock.calls.map(([sql]) => sql)).toEqual([
      'BEGIN READ WRITE',
      'SELECT user_id, workspace_id, workspace_type, workspace_name, created\n           FROM ledger.bootstrap_workspace($1::uuid, $2::text, $3::text)',
      'ROLLBACK',
    ])
    expect(authPool.connect).toHaveBeenCalledOnce()
    expect(client.release).toHaveBeenCalledOnce()
  })

  it('rejects unsigned or expired tokens before using a database connection', async () => {
    const { app, authPool } = setup()
    await request(app)
      .get('/api/v1/workspace/context')
      .set('Authorization', `Bearer ${makeToken({ exp: 1 })}`)
      .set('X-LedgerX-Workspace-ID', workspaceId)
      .expect(401, { error: 'invalid_access_token', message: 'A valid sign-in token is required.' })
    await request(app)
      .get('/api/v1/workspace/context')
      .set('Authorization', 'Bearer not-a-jwt')
      .set('X-LedgerX-Workspace-ID', workspaceId)
      .expect(401)
    expect(authPool.connect).not.toHaveBeenCalled()
  })

  it('requires an authenticated Supabase role and a valid workspace selector', async () => {
    const { app, authPool } = setup()
    await request(app)
      .get('/api/v1/workspace/context')
      .set('Authorization', `Bearer ${makeToken({ role: 'anon' })}`)
      .set('X-LedgerX-Workspace-ID', workspaceId)
      .expect(401)
    await request(app)
      .get('/api/v1/workspace/context')
      .set('Authorization', `Bearer ${makeToken()}`)
      .set('X-LedgerX-Workspace-ID', 'not-a-uuid')
      .expect(400, { error: 'workspace_id_required', message: 'A valid X-LedgerX-Workspace-ID header is required.' })
    expect(authPool.connect).not.toHaveBeenCalled()
  })

  it('rolls back and returns a generic denial when PostgreSQL rejects workspace membership', async () => {
    const membershipError = Object.assign(new Error('membership lookup details'), { code: '42501' })
    const { app, authPool, client } = setup({ queryError: membershipError })
    await request(app)
      .get('/api/v1/workspace/context')
      .set('Authorization', `Bearer ${makeToken()}`)
      .set('X-LedgerX-Workspace-ID', workspaceId)
      .expect(403, { error: 'workspace_access_denied', message: 'You do not have access to this workspace.' })
    expect(client.query.mock.calls.map(([sql]) => sql)).toEqual([
      'BEGIN READ ONLY',
      'SELECT user_id, membership_role FROM ledger.set_request_context($1::uuid, $2::uuid)',
      'ROLLBACK',
    ])
    expect(authPool.connect).toHaveBeenCalledOnce()
    expect(client.release).toHaveBeenCalledOnce()
  })

  it('does not expose authenticated workspace access when identity and API pool are not configured', async () => {
    const pool = { query: vi.fn(async () => ({ rows: [{ ok: 1 }] })) }
    const app = createApp({
      pool,
      reads: { health: async () => ({ status: 'ok' }) },
      logger: pino({ level: 'silent' }),
      allowedOrigins: [],
    })
    await request(app).get('/api/v1/workspace/context').expect(404)
  })
})
