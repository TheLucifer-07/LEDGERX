export function formatMoney(value, currency, minorUnit = 2) {
  if (value === null || value === undefined || !currency) return '—'
  const amount = Number(value)
  if (!Number.isFinite(amount)) return '—'
  try {
    return new Intl.NumberFormat(undefined, {
      style: 'currency', currency, minimumFractionDigits: minorUnit, maximumFractionDigits: minorUnit,
    }).format(amount)
  } catch {
    return `${currency} ${amount.toFixed(minorUnit)}`
  }
}

export function formatCount(value) {
  return new Intl.NumberFormat().format(Number(value || 0))
}

export function formatDate(value, options = {}) {
  if (!value) return '—'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return '—'
  const hasDatePartOptions = ['weekday', 'era', 'year', 'month', 'day', 'hour', 'minute', 'second', 'timeZoneName']
    .some((key) => options[key] !== undefined)
  const formatterOptions = hasDatePartOptions ? options : { dateStyle: 'medium', ...options }
  return new Intl.DateTimeFormat(undefined, formatterOptions).format(date)
}

export function formatDateTime(value) {
  if (!value) return '—'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return '—'
  return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date)
}

export function titleCase(value) {
  return String(value || '').replaceAll('_', ' ').replace(/\b\w/g, (letter) => letter.toUpperCase())
}
