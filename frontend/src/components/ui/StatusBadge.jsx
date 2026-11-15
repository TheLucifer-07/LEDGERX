import { titleCase } from '../../utils/format.js'

export default function StatusBadge({ value, tone }) {
  const normalized = String(value || 'unknown').toLowerCase()
  const color = tone || (['posted', 'matched', 'reconciled', 'closed', 'open'].includes(normalized)
    ? 'good' : ['pending', 'importing', 'imported', 'unsettled'].includes(normalized)
      ? 'warning' : ['reversed', 'failed', 'missing_internal', 'missing_external', 'amount_mismatch', 'currency_mismatch'].includes(normalized)
        ? 'bad' : 'neutral')
  return <span className={`status-badge status-${color}`}><i />{titleCase(normalized)}</span>
}
