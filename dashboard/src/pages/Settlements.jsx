import { useState } from 'react'
import { Search, X } from 'lucide-react'
import { useApi } from '../hooks/useApi.js'
import { formatDate, formatDateTime, formatMoney, titleCase } from '../utils/format.js'
import Panel from '../components/ui/Panel.jsx'
import SectionHeading from '../components/ui/SectionHeading.jsx'
import StatusBadge from '../components/ui/StatusBadge.jsx'
import DataTable from '../components/tables/DataTable.jsx'
import CurrencySelect from '../components/ui/CurrencySelect.jsx'

export default function Settlements() {
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState('')
  const [currency, setCurrency] = useState('')
  const [page, setPage] = useState(0)
  const [selected, setSelected] = useState(null)
  const result = useApi('/api/v1/settlements', { page, size: 20, search, status, currency })
  return <div className="page-stack">
    <div className="page-intro"><div><div className="eyebrow">EXTERNAL STATEMENT EVIDENCE</div><h2>Settlements</h2><p>Compare imported external statement batches against LedgerX transaction records.</p></div><span className="read-only-tag">INTERNAL & EXTERNAL KEPT DISTINCT</span></div>
    <Panel className="integrity-callout"><div className="callout-mark"><span className="settlement-mark">S</span></div><div><strong>Settlement records are not ledger postings.</strong><p>External amounts come from imported statement items; expected values come from persisted reconciliation results.</p></div></Panel>
    <Panel className="filter-panel"><div className="filter-toolbar"><label className="filter-search"><Search size={16} /><input aria-label="Search settlement batches" placeholder="Batch reference or source" value={search} onChange={(event) => { setPage(0); setSearch(event.target.value) }} /></label>
      <select aria-label="Filter settlement status" value={status} onChange={(event) => { setPage(0); setStatus(event.target.value) }}><option value="">All batch statuses</option>{['importing', 'imported', 'reconciled', 'closed'].map((value) => <option key={value} value={value}>{titleCase(value)}</option>)}</select>
      <CurrencySelect label="Filter settlement currency" value={currency} onChange={(value) => { setPage(0); setCurrency(value) }} /></div></Panel>
    <Panel className="table-panel"><SectionHeading title="Settlement batches" description="Choose a batch to inspect its actual imported items and internal match status." />
      <DataTable loading={result.loading} error={result.error} rows={result.data?.items || []} pagination={result.data} onPageChange={setPage} rowKey="settlement_batch_id" onRowClick={setSelected} emptyTitle="No settlement batches" emptyDescription="No batches match the selected filters."
        columns={[
          { key: 'external_batch_ref', label: 'External batch', render: (value) => <span className="mono strong-text">{value}</span> },
          { key: 'source_name', label: 'Statement source' },
          { key: 'statement_date', label: 'Statement date', render: (value) => formatDate(value) },
          { key: 'currency_code', label: 'Currency' },
          { key: 'external_gross_total', label: 'External total', numeric: true, render: (value, row) => formatMoney(value, row.currency_code) },
          { key: 'expected_gross_total', label: 'Expected total', numeric: true, render: (value, row) => formatMoney(value, row.currency_code) },
          { key: 'exception_count', label: 'Exceptions', numeric: true },
          { key: 'status', label: 'Status', render: (value) => <StatusBadge value={value} /> },
        ]} />
    </Panel>
    {selected && <SettlementDrawer batch={selected} onClose={() => setSelected(null)} />}
  </div>
}

function SettlementDrawer({ batch, onClose }) {
  const result = useApi(`/api/v1/settlements/${batch.settlement_batch_id}/items`, { page: 0, size: 50 })
  return <div className="drawer-scrim" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
    <aside className="detail-drawer wide-drawer" role="dialog" aria-modal="true" aria-labelledby="settlement-title">
      <div className="drawer-header"><div><div className="eyebrow">SETTLEMENT EVIDENCE</div><h2 id="settlement-title">Batch items</h2></div><button className="icon-button" aria-label="Close settlement details" onClick={onClose}><X size={18} /></button></div>
      <div className="settlement-drawer-head"><div><strong className="mono">{batch.external_batch_ref}</strong><small>{batch.source_name} · {formatDate(batch.statement_date)}</small></div><StatusBadge value={batch.status} /></div>
      <div className="detail-list"><Detail label="External statement total" value={formatMoney(batch.external_gross_total, batch.currency_code)} /><Detail label="Expected total" value={formatMoney(batch.expected_gross_total, batch.currency_code)} /><Detail label="Currency" value={batch.currency_code} /><Detail label="Latest reconciliation" value={batch.latest_run_number ? `Run ${batch.latest_run_number}` : 'Not run'} /><Detail label="Exceptions" value={batch.exception_count} /></div>
      <SectionHeading title="Imported items" description="External evidence matched to internal transaction references." />
      <DataTable loading={result.loading} error={result.error} rows={result.data?.items || []} rowKey="settlement_item_id" emptyTitle="No items in this batch" columns={[
        { key: 'external_ref', label: 'External ref', render: (value) => <span className="mono">{value}</span> },
        { key: 'internal_reference', label: 'Internal reference', render: (value) => <span className="mono">{value}</span> },
        { key: 'flow', label: 'Flow', render: (value) => titleCase(value) },
        { key: 'external_amount', label: 'External', numeric: true, render: (value, row) => formatMoney(value, row.currency_code) },
        { key: 'internal_amount', label: 'Internal', numeric: true, render: (value, row) => value == null ? '—' : formatMoney(value, row.internal_currency_code) },
        { key: 'match_status', label: 'Match', render: (value) => <StatusBadge value={value} /> },
        { key: 'external_at', label: 'Statement time', render: (value) => formatDateTime(value) },
      ]} />
    </aside>
  </div>
}

function Detail({ label, value }) { return <div className="detail-row"><span>{label}</span><strong>{value || '—'}</strong></div> }
