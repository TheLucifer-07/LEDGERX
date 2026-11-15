import { describe, expect, it } from 'vitest'
import { readConfig } from '../src/config/env.js'

const valid = {
  NODE_ENV: 'development',
  PORT: '8080',
  DATABASE_URL: 'postgresql://ledgerx_dashboard:local-only@127.0.0.1:55432/ledgerx',
  FRONTEND_ORIGINS: 'http://localhost:5173, http://127.0.0.1:5173',
  LOG_LEVEL: 'info',
}

describe('backend environment validation', () => {
  it('parses required connection settings and exact origins', () => {
    const config = readConfig(valid)
    expect(config.PORT).toBe(8080)
    expect(config.FRONTEND_ORIGINS).toEqual(['http://localhost:5173', 'http://127.0.0.1:5173'])
  })

  it('fails before startup when a required setting is missing', () => {
    expect(() => readConfig({ ...valid, DATABASE_URL: '' })).toThrow(/DATABASE_URL/)
  })

  it('rejects non-PostgreSQL URLs and wildcard browser origins', () => {
    expect(() => readConfig({ ...valid, DATABASE_URL: 'mysql://user:pass@localhost/db' })).toThrow(/PostgreSQL URL/)
    expect(() => readConfig({ ...valid, FRONTEND_ORIGINS: '*' })).toThrow(/wildcard origins are not allowed/)
  })

  it('refuses public production startup until authentication is implemented', () => {
    expect(() => readConfig({ ...valid, NODE_ENV: 'production' })).toThrow(/Production startup is disabled/)
  })
})
