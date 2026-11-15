import { useEffect, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { BookOpenCheck, Search, X } from 'lucide-react'
import { useApi } from '../hooks/useApi.js'
import { formatDateTime, formatMoney, titleCase } from '../utils/format.js'
import Panel from '../components/ui/Panel.jsx'
import SectionHeading from '../components/ui/SectionHeading.jsx'
import StatusBadge from '../components/ui/StatusBadge.jsx'
import DataTable from '../components/tables/DataTable.jsx'
import { EmptyState, ErrorState, LoadingState } from '../components/ui/DataState.jsx'
import CurrencySelect from '../components/ui/CurrencySelect.jsx'

export default function LedgerExplorer() {
  const [searchParams, setSearchParams] = useSearchParams()
  const [search, setSearch] = useState('')
  const [side, setSide] = useState('')
  const [currency, setCurrency] = useState('')
  const [page, setPage] = useState(0)
  const initialId = Number(searchParams.get('journal')) || null
  const [selectedId, setSelectedId] = useState(initialId)
  const result = useApi('/api/v1/ledger/entries', { page, size: 25, search, side, currency })
  useEffect(() => {
    const id = Number(searchParams.get('journal')) || null
    if (id !== selectedId) setSelectedId(id)
  }, [searchParams])

  function selectJournal(id) { setSelectedId(id); setSearchParams({ journal: String(id) }) }
  function closeJournal() { setSelectedId(null); setSearchParams({}) }

  return <div className="page-stack">
    <div className="page-intro"><div><div className="eyebrow">DOUBLE-ENTRY ACCOUNTING</div><h2>Ledger explorer</h2><p>Inspect immutable journal lines, their account sides and the database integrity auditor's result.</p></div><span className="read-only-tag"><BookOpenCheck size={13} /> POSTED JOURNALS</span></div>
    <Panel className="integrity-callout"><div className="callout-mark"><BookOpenCheck size={18} /></div><div><strong>Every journal is evaluated as a pair.</strong><p>Debit and credit totals are shown separately. Journal findings come from <span className="mono">ledger.audit_integrity()</span>; account balances are projections, not proof of balance.</p></div></Panel>
    <Panel className="filter-panel"><div className="filter-toolbar">
      <label className="filter-search"><Search size={16} /><input aria-label="Search journal entries" placeholder="Journal reference or account" value={search} onChange={(event) => { setPage(0); setSearch(event.target.value) }} /></label>
      <select aria-label="Filter entry side" value={side} onChange={(event) => { setPage(0); setSide(event.target.value) }}><option value="">All entry sides</option><option value="debit">Debit</option><option value="credit">Credit</option></select>
      <CurrencySelect label="Filter ledger currency" value={currency} onChange={(value) => { setPage(0); setCurrency(value) }} />
    </div></Panel>
    <Panel className="table-panel"><SectionHeading title="Journal lines" description="Each row is an append-only entry in the internal ledger." />
      <DataTable loading={result.loading} error={result.error} rows={result.data?.items || []} pagination={result.data} onPageChange={setPage} rowKey="ledger_entry_id" onRowClick={(row) => selectJournal(row.transaction_id)} emptyTitle="No journal entries" emptyDescription="There are no entries for the selected filters."
        columns={[
          { key: 'transaction_ref', label: 'Journal transaction', render: (value, row) => <div className="cell-stack"><strong className="mono">{value}</strong><small>{titleCase(row.transaction_type)}</small></div> },
          { key: 'ledger_entry_id', label: 'Entry ID', render: (value) => <span className="mono muted">#{value}</span> },
          { key: 'account_code', label: 'Account', render: (value) => <span className="mono">{value}</span> },
          { key: 'entry_side', label: 'Side', render: (value) => <span className={`entry-side entry-${value}`}>{titleCase(value)}</span> },
          { key: 'amount', label: 'Amount', numeric: true, render: (value, row) => <span className="amount-text">{formatMoney(value, row.currency_code)}</span> },
          { key: 'posted_at', label: 'Posted at', render: (value) => formatDateTime(value) },
          { key: 'transaction_status', label: 'Journal state', render: (value) => <StatusBadge value={value} /> },
        ]} />
    </Panel>
    {selectedId && <JournalDrawer id={selectedId} onClose={closeJournal} />}
  </div>
}

function JournalDrawer({ id, onClose }) {
  const journal = useApi(`/api/v1/ledger/journals/${id}`)
  const record = journal.data
  const totals = record?.totals
  return <div className="drawer-scrim" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
    <aside className="detail-drawer wide-drawer" role="dialog" aria-modal="true" aria-labelledby="journal-detail-title">
      <div className="drawer-header"><div><div className="eyebrow">JOURNAL INSPECTION</div><h2 id="journal-detail-title">Journal balance</h2></div><button className="icon-button" aria-label="Close journal details" onClick={onClose}><X size={18} /></button></div>
      {journal.loading ? <LoadingState label="Loading journal and integrity findings" /> : journal.error ? <ErrorState message={journal.error} /> : record && <>
        <div className="journal-title-row"><div><strong className="mono">{record.transaction.transaction_ref}</strong><small>{titleCase(record.transaction.transaction_type)} · {formatDateTime(record.transaction.posted_at)}</small></div><StatusBadge value={totals.balanced ? 'balanced' : 'unbalanced'} tone={totals.balanced ? 'good' : 'bad'} /></div>
        <div className="journal-total-grid"><div><span>Total debits</span><strong>{formatMoney(totals.debit_total, record.transaction.currency_code)}</strong></div><div><span>Total credits</span><strong>{formatMoney(totals.credit_total, record.transaction.currency_code)}</strong></div><div><span>Journal lines</span><strong>{totals.line_count}</strong></div></div>
        {record.audit_findings.length > 0 && <div className="finding-banner"><strong>Integrity auditor flagged this journal.</strong><p>{record.audit_findings.map((finding) => `${finding.finding_type}: ${finding.details}`).join(' · ')}</p></div>}
        {record.audit_findings.length === 0 && <div className="audit-pass"><BookOpenCheck size={16} /><span>No unbalanced-journal finding for this transaction in the database audit.</span></div>}
        <SectionHeading title="Entry lines" description="Debit and credit postings, grouped by the recorded journal." />
        <DataTable rows={record.entries} rowKey="ledger_entry_id" emptyTitle="No journal lines" columns={[
          { key: 'ledger_entry_id', label: 'Entry' }, { key: 'account_code', label: 'Account', render: (value, row) => <div className="cell-stack"><strong className="mono">{value}</strong><small>{titleCase(row.account_kind)}</small></div> },
          { key: 'entry_side', label: 'Side', render: (value) => <span className={`entry-side entry-${value}`}>{titleCase(value)}</span> },
          { key: 'debit', label: 'Debit', numeric: true, render: (_, row) => row.entry_side === 'debit' ? formatMoney(row.amount, row.currency_code) : '—' },
          { key: 'credit', label: 'Credit', numeric: true, render: (_, row) => row.entry_side === 'credit' ? formatMoney(row.amount, row.currency_code) : '—' },
          { key: 'currency_code', label: 'Currency' },
        ]} />
      </>}
    </aside>
  </div>
}
