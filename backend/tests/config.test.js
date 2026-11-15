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

  it('enables authenticated workspace access only with both identity and API database settings', () => {
    expect(() => readConfig({ ...valid, SUPABASE_URL: 'https://ledgerx.example.supabase.co' }))
      .toThrow(/AUTH_DATABASE_URL and SUPABASE_URL must be configured together/)
    const config = readConfig({
      ...valid,
      AUTH_DATABASE_URL: 'postgresql://ledgerx_api:local-only@127.0.0.1:55432/ledgerx',
      SUPABASE_URL: 'https://ledgerx.example.supabase.co',
      SUPABASE_JWKS_URL: 'https://ledgerx.example.supabase.co/auth/v1/.well-known/jwks.json',
    })
    expect(config.SUPABASE_URL).toBe('https://ledgerx.example.supabase.co')
  })

  it('allows loopback HTTP auth for local Supabase and rejects remote HTTP', () => {
    expect(readConfig({
      ...valid,
      AUTH_DATABASE_URL: valid.DATABASE_URL,
      SUPABASE_URL: 'http://localhost:54321',
    }).SUPABASE_URL).toBe('http://localhost:54321')
    expect(() => readConfig({
      ...valid,
      AUTH_DATABASE_URL: valid.DATABASE_URL,
      SUPABASE_URL: 'http://auth.example.test',
    })).toThrow(/HTTPS Supabase project URL or a loopback HTTP URL/)
  })

  it('refuses public production startup until authentication is implemented', () => {
    expect(() => readConfig({ ...valid, NODE_ENV: 'production' })).toThrow(/Production startup is disabled/)
  })
})
