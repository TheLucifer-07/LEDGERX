import { useMemo } from 'react'
import { useDashboardContext } from '../contexts/DashboardContext.jsx'

function isoDate(date) {
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000)
  return local.toISOString().slice(0, 10)
}

export function useDateRange() {
  const { period } = useDashboardContext()
  return useMemo(() => {
    if (period === 'all') return { from: '', to: '' }
    const days = Number.parseInt(period, 10) || 30
    const today = new Date()
    const from = new Date(today)
    from.setDate(from.getDate() - days + 1)
    return { from: isoDate(from), to: isoDate(today) }
  }, [period])
}
