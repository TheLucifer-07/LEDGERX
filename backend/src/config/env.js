import { z } from 'zod'

const schema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  HOST: z.string().trim().min(1).default('127.0.0.1'),
  PORT: z.coerce.number().int().min(1).max(65535).default(8080),
  DATABASE_URL: z.string().min(1).refine(isPostgresUrl, 'must use a PostgreSQL URL'),
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
    throw new Error('Production startup is disabled until Supabase authentication and workspace authorization are enabled.')
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
