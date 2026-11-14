import { useEffect, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { ExternalLink, Search, X } from 'lucide-react'
import { useApi } from '../hooks/useApi.js'
import { useDateRange } from '../hooks/useDateRange.js'
import { formatDateTime, formatMoney, titleCase } from '../utils/format.js'
import Panel from '../components/ui/Panel.jsx'
import SectionHeading from '../components/ui/SectionHeading.jsx'
import StatusBadge from '../components/ui/StatusBadge.jsx'
import DataTable from '../components/tables/DataTable.jsx'
import CurrencySelect from '../components/ui/CurrencySelect.jsx'

export default function Transactions() {
  const [searchParams, setSearchParams] = useSearchParams()
  const [query, setQuery] = useState(searchParams.get('search') || '')
  const [filters, setFilters] = useState({ status: '', type: '', currency: '' })
  const [page, setPage] = useState(0)
  const [selected, setSelected] = useState(null)
  const dates = useDateRange()
  const params = { page, size: 20, search: searchParams.get('search') || '', ...filters, ...dates }
  const result = useApi('/api/v1/transactions', params)
  useEffect(() => setQuery(searchParams.get('search') || ''), [searchParams])

  function submitSearch(event) {
    event.preventDefault()
    setPage(0)
    const next = new URLSearchParams(searchParams)
    if (query.trim()) next.set('search', query.trim()); else next.delete('search')
    setSearchParams(next)
  }

  function changeFilter(key, value) { setPage(0); setFilters((current) => ({ ...current, [key]: value })) }

  return <div className="page-stack">
    <div className="page-intro"><div><div className="eyebrow">PAYMENTS & ACCOUNT MOVEMENT</div><h2>Transactions</h2><p>Browse posted financial operations and their current lifecycle status.</p></div>
      <span className="read-only-tag">READ ONLY</span></div>
    <Panel className="filter-panel"><form className="filter-toolbar" onSubmit={submitSearch}>
      <label className="filter-search"><Search size={16} /><input aria-label="Filter transactions" placeholder="Reference or account code" value={query} onChange={(event) => setQuery(event.target.value)} /><button type="submit">Search</button></label>
      <select aria-label="Filter by status" value={filters.status} onChange={(event) => changeFilter('status', event.target.value)}><option value="">All statuses</option><option value="posted">Posted</option><option value="reversed">Reversed</option><option value="pending">Pending</option></select>
      <select aria-label="Filter by type" value={filters.type} onChange={(event) => changeFilter('type', event.target.value)}><option value="">All types</option>{['deposit', 'withdrawal', 'transfer', 'capture', 'refund', 'reversal'].map((value) => <option key={value} value={value}>{titleCase(value)}</option>)}</select>
      <CurrencySelect label="Filter by currency" value={filters.currency} onChange={(value) => changeFilter('currency', value)} />
    </form></Panel>
    <Panel className="table-panel"><SectionHeading title="Transaction register" description="Amounts are shown in their transaction currency. Select a row for details." />
      <DataTable loading={result.loading} error={result.error} onRetry={() => window.location.reload()} rows={result.data?.items || []} pagination={result.data} onPageChange={setPage} onRowClick={(row) => setSelected(row.transaction_id)} rowKey="transaction_id" emptyTitle="No transactions match" emptyDescription="Try another search or filter."
        columns={[
          { key: 'transaction_ref', label: 'Transaction reference', render: (value) => <span className="mono strong-text">{value}</span> },
          { key: 'transaction_type', label: 'Type', render: (value) => <span>{titleCase(value)}</span> },
          { key: 'source_account_code', label: 'Source account', render: (value) => <span className="mono small-text">{value}</span> },
          { key: 'destination_account_code', label: 'Destination account', render: (value) => <span className="mono small-text">{value}</span> },
          { key: 'amount', label: 'Amount', numeric: true, render: (value, row) => <span className="amount-text">{formatMoney(value, row.currency_code)}</span> },
          { key: 'status', label: 'Status', render: (value) => <StatusBadge value={value} /> },
          { key: 'created_at', label: 'Created', render: (value) => formatDateTime(value) },
        ]} />
    </Panel>
    {selected && <TransactionDrawer id={selected} onClose={() => setSelected(null)} />}
  </div>
}

function TransactionDrawer({ id, onClose }) {
  const result = useApi(`/api/v1/transactions/${id}`)
  const tx = result.data
  return <div className="drawer-scrim" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
    <aside className="detail-drawer" role="dialog" aria-modal="true" aria-labelledby="transaction-detail-title">
      <div className="drawer-header"><div><div className="eyebrow">TRANSACTION RECORD</div><h2 id="transaction-detail-title">Details</h2></div><button className="icon-button" aria-label="Close details" onClick={onClose}><X size={18} /></button></div>
      {result.loading ? <div className="drawer-loading">Loading ledger record…</div> : result.error ? <div className="error-inline">{result.error}</div> : tx && <>
        <div className="detail-primary"><div className="detail-ref mono">{tx.transaction_ref}</div><StatusBadge value={tx.status} /><div className="detail-amount">{formatMoney(tx.amount, tx.currency_code)}</div><div className="detail-kind">{titleCase(tx.transaction_type)}</div></div>
        <div className="detail-list"><Detail label="Source account" value={tx.source_account_code} /><Detail label="Destination account" value={tx.destination_account_code} /><Detail label="Created" value={formatDateTime(tx.created_at)} /><Detail label="Posted" value={formatDateTime(tx.posted_at)} /><Detail label="Request reference" value={tx.request_reference || '—'} /><Detail label="Reversed transaction" value={tx.reversed_transaction_ref || '—'} /></div>
        <a className="drawer-action" href={`/ledger?journal=${tx.transaction_id}`}><ExternalLink size={15} /> Inspect journal entries</a>
        <p className="drawer-note">This console cannot post, edit, refund or reverse transactions.</p>
      </>}
    </aside>
  </div>
}

function Detail({ label, value }) { return <div className="detail-row"><span>{label}</span><strong>{value || '—'}</strong></div> }
