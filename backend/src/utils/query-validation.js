import { z } from 'zod'
import { HttpError } from './http-error.js'

const pageSchema = z.object({
  page: z.coerce.number().int().min(0).max(1_000_000).default(0),
  size: z.coerce.number().int().min(1).max(100).default(20),
})

const dateSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/)

export function parsePage(query, defaults = {}) {
  const parsed = pageSchema.extend({
    page: pageSchema.shape.page.default(defaults.page ?? 0),
    size: pageSchema.shape.size.default(defaults.size ?? 20),
  }).safeParse(query)
  if (!parsed.success) throw invalidQuery(parsed.error)
  return parsed.data
}

export function parseDateRange(query) {
  const parsed = z.object({ from: dateSchema.optional(), to: dateSchema.optional() }).safeParse(query)
  if (!parsed.success) throw invalidQuery(parsed.error)
  const { from, to } = parsed.data
  if ((from && !isCalendarDate(from)) || (to && !isCalendarDate(to))) {
    throw new HttpError(400, 'invalid_date', 'Dates must be valid calendar dates in YYYY-MM-DD format.')
  }
  if (from && to && to < from) {
    throw new HttpError(400, 'invalid_date_range', 'The end date must be on or after the start date.')
  }
  return { from: from ?? null, to: to ?? null }
}

export function parseId(value, label = 'id') {
  if (!/^[1-9]\d{0,18}$/.test(value ?? '')) {
    throw new HttpError(400, 'invalid_identifier', `${label} must be a positive integer.`)
  }
  return value
}

export function parseOptionalText(value, maxLength = 100) {
  if (value === undefined || value === '') return null
  const parsed = z.string().trim().max(maxLength).safeParse(value)
  if (!parsed.success) throw invalidQuery(parsed.error)
  return parsed.data || null
}

export function parseSort(value, allowed, fallback) {
  return allowed.includes(value) ? value : fallback
}

export function parseDirection(value, fallback = 'desc') {
  return value?.toLowerCase() === 'asc' ? 'ASC' : value?.toLowerCase() === 'desc' ? 'DESC' : fallback.toUpperCase()
}

function isCalendarDate(value) {
  const date = new Date(`${value}T00:00:00.000Z`)
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value
}

function invalidQuery(error) {
  const detail = error.issues.map((issue) => `${issue.path.join('.') || 'query'}: ${issue.message}`).join('; ')
  return new HttpError(400, 'invalid_query', detail)
}
