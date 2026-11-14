import { useState } from 'react'
import { GitCompareArrows, Search } from 'lucide-react'
import { useApi } from '../hooks/useApi.js'
import { formatDateTime, formatMoney, formatCount, titleCase } from '../utils/format.js'
import Panel from '../components/ui/Panel.jsx'
import SectionHeading from '../components/ui/SectionHeading.jsx'
import StatusBadge from '../components/ui/StatusBadge.jsx'
import DataTable from '../components/tables/DataTable.jsx'

const tabs = [
  { id: 'runs', label: 'Run history' },
  { id: 'exceptions', label: 'Exceptions' },
  { id: 'unsettled', label: 'Unsettled transactions' },
]

export default function Reconciliation() {
  const [tab, setTab] = useState('runs')
  const [type, setType] = useState('')
  const [search, setSearch] = useState('')
  const [page, setPage] = useState(0)
  const path = tab === 'runs' ? '/api/v1/reconciliation/runs' : tab === 'exceptions' ? '/api/v1/reconciliation/exceptions' : '/api/v1/reconciliation/unsettled'
  const result = useApi(path, tab === 'exceptions' ? { page, size: 25, type, search } : { page, size: 25 })
  const items = result.data?.items || []
  const counts = tab === 'runs' ? items.reduce((acc, row) => ({ total: acc.total + Number(row.item_count || 0), matched: acc.matched + Number(row.matched_count || 0) }), { total: 0, matched: 0 }) : null

  return <div className="page-stack">
    <div className="page-intro"><div><div className="eyebrow">STATEMENT-TO-LEDGER MATCHING</div><h2>Reconciliation</h2><p>See matched external statement items, exceptions, and posted transactions still awaiting settlement.</p></div><span className="read-only-tag"><GitCompareArrows size={14} /> PERSISTED RESULTS</span></div>
    <div className="reconciliation-summary">
      <div className="recon-summary-card"><span>Scope</span><strong>External statement ↔ internal ledger</strong></div>
      <div className="recon-summary-card"><span>{tab === 'runs' ? 'Rows on this page' : 'Matching records'}</span><strong>{formatCount(items.length)}</strong></div>
      {counts && <div className="recon-summary-card"><span>Matched on this page</span><strong>{formatCount(counts.matched)} <small>/ {formatCount(counts.total)}</small></strong></div>}
    </div>
    <Panel className="table-panel reconciliation-panel">
      <div className="tab-row" role="tablist" aria-label="Reconciliation views">{tabs.map((item) => <button key={item.id} role="tab" aria-selected={tab === item.id} className={tab === item.id ? 'tab-active' : ''} onClick={() => { setTab(item.id); setPage(0) }}>{item.label}</button>)}</div>
      {tab === 'exceptions' && <div className="filter-toolbar compact-toolbar"><label className="filter-search"><Search size={16} /><input aria-label="Search reconciliation exceptions" placeholder="Batch, transaction or external ref" value={search} onChange={(event) => { setPage(0); setSearch(event.target.value) }} /></label>
        <select aria-label="Filter exception type" value={type} onChange={(event) => { setPage(0); setType(event.target.value) }}><option value="">All exception types</option>{['missing_internal', 'missing_external', 'amount_mismatch', 'currency_mismatch', 'transaction_type_mismatch', 'unsettled'].map((value) => <option key={value} value={value}>{titleCase(value)}</option>)}</select></div>}
      {tab === 'runs' && <>
        <SectionHeading title="Reconciliation runs" description="Each run records the comparison against an imported external batch." />
        <DataTable loading={result.loading} error={result.error} rows={items} pagination={result.data} onPageChange={setPage} rowKey="reconciliation_run_id" emptyTitle="No reconciliation runs" emptyDescription="Reconciliation run history will appear when imported batches are processed."
          columns={[
            { key: 'external_batch_ref', label: 'Batch', render: (value) => <span className="mono strong-text">{value}</span> },
            { key: 'run_number', label: 'Run' }, { key: 'started_at', label: 'Started', render: (value) => formatDateTime(value) },
            { key: 'completed_at', label: 'Completed', render: (value) => formatDateTime(value) },
            { key: 'item_count', label: 'Items', numeric: true },
            { key: 'matched_count', label: 'Matched', numeric: true },
            { key: 'missing_internal_count', label: 'Missing internal', numeric: true },
            { key: 'missing_external_count', label: 'Missing external', numeric: true },
            { key: 'amount_mismatch_count', label: 'Amount mismatch', numeric: true },
            { key: 'currency_mismatch_count', label: 'Currency mismatch', numeric: true },
          ]} />
      </>}
      {tab === 'exceptions' && <>
        <SectionHeading title="Reconciliation exceptions" description="Persisted mismatches from the database reconciliation results." />
        <DataTable loading={result.loading} error={result.error} rows={items} pagination={result.data} onPageChange={setPage} rowKey="reconciliation_result_id" emptyTitle="No exceptions found" emptyDescription="No persisted reconciliation results match the filters."
          columns={[
            { key: 'external_batch_ref', label: 'Batch', render: (value) => <span className="mono">{value}</span> },
            { key: 'run_number', label: 'Run' },
            { key: 'result_type', label: 'Finding', render: (value) => <StatusBadge value={value} /> },
            { key: 'transaction_ref', label: 'Internal transaction', render: (value) => value ? <span className="mono">{value}</span> : '—' },
            { key: 'external_ref', label: 'External reference', render: (value) => value ? <span className="mono">{value}</span> : '—' },
            { key: 'expected_amount', label: 'Expected', numeric: true, render: (value, row) => value == null ? '—' : formatMoney(value, row.expected_currency_code) },
            { key: 'external_amount', label: 'External', numeric: true, render: (value, row) => value == null ? '—' : formatMoney(value, row.external_currency_code) },
            { key: 'evaluated_at', label: 'Evaluated', render: (value) => formatDateTime(value) },
          ]} />
      </>}
      {tab === 'unsettled' && <>
        <SectionHeading title="Unsettled posted transactions" description="Posted captures and refunds without a one-to-one external statement match." />
        <DataTable loading={result.loading} error={result.error} rows={items} pagination={result.data} onPageChange={setPage} rowKey="transaction_id" emptyTitle="No unsettled transactions" emptyDescription="There are no posted captures or refunds waiting for an external match."
          columns={[
            { key: 'transaction_ref', label: 'Transaction', render: (value) => <span className="mono strong-text">{value}</span> },
            { key: 'transaction_type', label: 'Flow', render: (value) => titleCase(value) },
            { key: 'amount', label: 'Amount', numeric: true, render: (value, row) => formatMoney(value, row.currency_code) },
            { key: 'currency_code', label: 'Currency' },
            { key: 'posted_at', label: 'Posted at', render: (value) => formatDateTime(value) },
            { key: 'elapsed_since_posting', label: 'Elapsed', render: (value) => value || '—' },
          ]} />
      </>}
    </Panel>
    <div className="footnote-line"><GitCompareArrows size={14} /> External statement items are evidence; only internal transaction and journal rows change account balances.</div>
  </div>
}
