import { useState } from 'react'
import { RotateCcw, Search } from 'lucide-react'
import { useApi } from '../hooks/useApi.js'
import { formatDateTime, formatMoney, titleCase } from '../utils/format.js'
import Panel from '../components/ui/Panel.jsx'
import SectionHeading from '../components/ui/SectionHeading.jsx'
import StatusBadge from '../components/ui/StatusBadge.jsx'
import DataTable from '../components/tables/DataTable.jsx'

export default function Refunds() {
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState('')
  const [page, setPage] = useState(0)
  const result = useApi('/api/v1/refunds', { page, size: 25, search, status })
  return <div className="page-stack">
    <div className="page-intro"><div><div className="eyebrow">COMPENSATING JOURNAL ACTIVITY</div><h2>Refunds & reversals</h2><p>Trace each refund to its original capture and any compensating reversal.</p></div><span className="read-only-tag">NO MUTATIONS</span></div>
    <Panel className="integrity-callout refund-callout"><div className="callout-mark"><RotateCcw size={18} /></div><div><strong>Refunds are separate posted transactions.</strong><p>Active and remaining refundable amounts are sourced from <span className="mono">ledger.v_refund_analysis</span>. A reversal adds compensating ledger lines; it does not erase posted history.</p></div></Panel>
    <Panel className="filter-panel"><div className="filter-toolbar"><label className="filter-search"><Search size={16} /><input aria-label="Search refunds" placeholder="Capture or refund reference" value={search} onChange={(event) => { setPage(0); setSearch(event.target.value) }} /></label>
      <select aria-label="Filter refund status" value={status} onChange={(event) => { setPage(0); setStatus(event.target.value) }}><option value="">All refund statuses</option><option value="posted">Posted</option><option value="reversed">Reversed</option></select></div></Panel>
    <Panel className="table-panel"><SectionHeading title="Refund history" description="Historical rows remain visible even when a refund is reversed." />
      <DataTable loading={result.loading} error={result.error} rows={result.data?.items || []} pagination={result.data} onPageChange={setPage} rowKey="refund_id" emptyTitle="No refund records" emptyDescription="Refunds are recorded after a capture has been posted."
        columns={[
          { key: 'capture_reference', label: 'Original capture', render: (value) => <span className="mono strong-text">{value}</span> },
          { key: 'refund_reference', label: 'Refund transaction', render: (value) => <span className="mono">{value}</span> },
          { key: 'amount', label: 'Refund amount', numeric: true, render: (value, row) => <span className="amount-text">{formatMoney(value, row.currency_code)}</span> },
          { key: 'refunded_amount', label: 'Active refunded', numeric: true, render: (value, row) => formatMoney(value, row.currency_code) },
          { key: 'historical_refund_amount', label: 'Historical refunds', numeric: true, render: (value, row) => formatMoney(value, row.currency_code) },
          { key: 'remaining_refundable_amount', label: 'Remaining', numeric: true, render: (value, row) => formatMoney(value, row.currency_code) },
          { key: 'reversal_reference', label: 'Reversal reference', render: (value) => value ? <span className="mono">{value}</span> : <span className="muted">—</span> },
          { key: 'refund_status', label: 'Status', render: (value) => <StatusBadge value={value} /> },
          { key: 'created_at', label: 'Recorded', render: (value) => formatDateTime(value) },
        ]} />
    </Panel>
    <div className="footnote-line"><RotateCcw size={14} /> A refund reference points to its own journal transaction. The capture remains separately traceable.</div>
  </div>
}
