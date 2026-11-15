import { z } from 'zod'

const schema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  HOST: z.string().trim().min(1).default('127.0.0.1'),
  PORT: z.coerce.number().int().min(1).max(65535).default(8080),
  DATABASE_URL: z.string().min(1).refine(isPostgresUrl, 'must use a PostgreSQL URL'),
  AUTH_DATABASE_URL: z.string().default('').refine((value) => !value || isPostgresUrl(value), 'must use a PostgreSQL URL'),
  SUPABASE_URL: z.string().default('').refine((value) => !value || isSupabaseUrl(value), 'must be an HTTPS Supabase project URL or a loopback HTTP URL'),
  SUPABASE_JWKS_URL: z.string().default('').refine((value) => !value || isJwksUrl(value), 'must be an HTTPS JWKS URL or a loopback HTTP URL'),
  FRONTEND_ORIGINS: z.string().default('http://localhost:5173,http://127.0.0.1:5173'),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent']).default('info'),
})

export function readConfig(source = process.env) {
  const parsed = schema.safeParse(source)
  if (!parsed.success) {
    const details = parsed.error.issues.map((issue) => `${issue.path.join('.')}: ${issue.message}`).join('; ')
    throw new Error(`Invalid backend configuration: ${details}`)
  }

  if (parsed.data.NODE_ENV === 'production') {
    throw new Error('Production startup is disabled until end-to-end authentication, product workflows, and deployment safeguards are verified.')
  }

  const hasAuthDatabase = Boolean(parsed.data.AUTH_DATABASE_URL)
  const hasSupabaseUrl = Boolean(parsed.data.SUPABASE_URL)
  if (hasAuthDatabase !== hasSupabaseUrl) {
    throw new Error('Invalid backend configuration: AUTH_DATABASE_URL and SUPABASE_URL must be configured together.')
  }
  if (parsed.data.SUPABASE_JWKS_URL && !hasSupabaseUrl) {
    throw new Error('Invalid backend configuration: SUPABASE_JWKS_URL requires SUPABASE_URL.')
  }

  const origins = parsed.data.FRONTEND_ORIGINS.split(',').map((origin) => origin.trim()).filter(Boolean)
  if (origins.some((origin) => origin.includes('*') || !isOrigin(origin))) {
    throw new Error('Invalid backend configuration: FRONTEND_ORIGINS must contain exact HTTP(S) origins; wildcard origins are not allowed.')
  }

  return {
    ...parsed.data,
    FRONTEND_ORIGINS: origins,
  }
}

function isOrigin(value) {
  try {
    const url = new URL(value)
    return ['http:', 'https:'].includes(url.protocol) && url.origin === value
      && !url.username && !url.password
  } catch {
    return false
  }
}

function isPostgresUrl(value) {
  try {
    return ['postgres:', 'postgresql:'].includes(new URL(value).protocol)
  } catch {
    return false
  }
}

function isSupabaseUrl(value) {
  try {
    const url = new URL(value)
    return (url.protocol === 'https:' || (url.protocol === 'http:' && isLoopbackHost(url.hostname)))
      && url.origin === value && !url.username && !url.password
  } catch {
    return false
  }
}

function isJwksUrl(value) {
  try {
    const url = new URL(value)
    return (url.protocol === 'https:' || (url.protocol === 'http:' && isLoopbackHost(url.hostname)))
      && !url.username && !url.password
  } catch {
    return false
  }
}

function isLoopbackHost(hostname) {
  return hostname === 'localhost' || hostname.endsWith('.localhost')
    || hostname === '::1' || hostname === '[::1]' || /^127\./.test(hostname)
}
