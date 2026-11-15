import { describe, expect, it } from 'vitest'
import { formatDate, formatMoney } from './format.js'

describe('format utilities', () => {
  it('formats compact chart labels without conflicting Intl date style options', () => {
    expect(formatDate('2026-11-14', { month: 'short', day: 'numeric' })).toMatch(/[A-Za-z]{3}\s?14|14\s?[A-Za-z]{3}/)
  })

  it('keeps financial amounts attached to an explicit currency', () => {
    expect(formatMoney('12.50', 'USD')).toContain('12.50')
    expect(formatMoney('12.50', '')).toBe('—')
  })
})
