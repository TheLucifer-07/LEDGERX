import { useState } from 'react'
import { Search, X } from 'lucide-react'
import { useApi } from '../hooks/useApi.js'
import { formatDateTime, formatMoney, titleCase } from '../utils/format.js'
import Panel from '../components/ui/Panel.jsx'
import SectionHeading from '../components/ui/SectionHeading.jsx'
import StatusBadge from '../components/ui/StatusBadge.jsx'
import DataTable from '../components/tables/DataTable.jsx'
import CurrencySelect from '../components/ui/CurrencySelect.jsx'

export default function Accounts() {
  const [search, setSearch] = useState('')
  const [kind, setKind] = useState('')
  const [status, setStatus] = useState('')
  const [currency, setCurrency] = useState('')
  const [page, setPage] = useState(0)
  const [selected, setSelected] = useState(null)
  const result = useApi('/api/v1/accounts', { page, size: 20, search, kind, status, currency })
  return <div className="page-stack">
    <div className="page-intro"><div><div className="eyebrow">CUSTOMER & CLEARING ACCOUNTS</div><h2>Accounts</h2><p>Review account ownership, status, currency and the posted balance projection.</p></div><span className="read-only-tag">READ ONLY</span></div>
    <Panel className="filter-panel"><div className="filter-toolbar">
      <label className="filter-search"><Search size={16} /><input aria-label="Search accounts" placeholder="Account code or customer" value={search} onChange={(event) => { setPage(0); setSearch(event.target.value) }} /></label>
      <select aria-label="Filter by account kind" value={kind} onChange={(event) => { setPage(0); setKind(event.target.value) }}><option value="">All account types</option>{['customer_wallet', 'merchant_wallet', 'funding_clearing', 'payout_clearing'].map((value) => <option key={value} value={value}>{titleCase(value)}</option>)}</select>
      <select aria-label="Filter accounts by status" value={status} onChange={(event) => { setPage(0); setStatus(event.target.value) }}><option value="">All statuses</option><option value="open">Open</option><option value="frozen">Frozen</option><option value="closed">Closed</option></select>
      <CurrencySelect label="Filter accounts by currency" value={currency} onChange={(value) => { setPage(0); setCurrency(value) }} />
    </div></Panel>
    <Panel className="table-panel"><SectionHeading title="Account directory" description="Customer display names come from the fictional seed records." />
      <DataTable loading={result.loading} error={result.error} rows={result.data?.items || []} pagination={result.data} onPageChange={setPage} rowKey="account_id" onRowClick={(row) => setSelected(row.account_id)} emptyTitle="No accounts match" emptyDescription="Change or clear your filters."
        columns={[
          { key: 'account_code', label: 'Account', render: (value) => <span className="mono strong-text">{value}</span> },
          { key: 'customer_name', label: 'Customer', render: (value, row) => <div className="cell-stack"><strong>{value || 'Ledger clearing account'}</strong><small>{row.customer_ref || 'Internal account'}</small></div> },
          { key: 'account_kind', label: 'Type', render: (value) => titleCase(value) },
          { key: 'currency_code', label: 'Currency' },
          { key: 'posted_balance', label: 'Posted balance', numeric: true, render: (value, row) => <span className="amount-text">{formatMoney(value, row.currency_code)}</span> },
          { key: 'status', label: 'Status', render: (value) => <StatusBadge value={value} /> },
          { key: 'balance_updated_at', label: 'Balance updated', render: (value) => formatDateTime(value) },
        ]} />
    </Panel>
    {selected && <AccountDrawer id={selected} onClose={() => setSelected(null)} />}
  </div>
}

function AccountDrawer({ id, onClose }) {
  const account = useApi(`/api/v1/accounts/${id}`)
  const activity = useApi(`/api/v1/accounts/${id}/activity`, { page: 0, size: 8 })
  const row = account.data
  return <div className="drawer-scrim" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
    <aside className="detail-drawer wide-drawer" role="dialog" aria-modal="true" aria-labelledby="account-detail-title">
      <div className="drawer-header"><div><div className="eyebrow">ACCOUNT PROFILE</div><h2 id="account-detail-title">Activity & balance</h2></div><button className="icon-button" aria-label="Close account details" onClick={onClose}><X size={18} /></button></div>
      {account.loading ? <div className="drawer-loading">Loading account…</div> : account.error ? <div className="error-inline">{account.error}</div> : row && <>
        <div className="account-drawer-summary"><div><small>{row.account_code}</small><strong>{formatMoney(row.posted_balance, row.currency_code)}</strong><span>Posted balance projection · {row.currency_code}</span></div><StatusBadge value={row.status} /></div>
        <div className="detail-list"><Detail label="Customer" value={row.customer_name || 'Internal clearing account'} /><Detail label="Account kind" value={titleCase(row.account_kind)} /><Detail label="Currency" value={row.currency_code} /><Detail label="Created" value={formatDateTime(row.created_at)} /><Detail label="Balance projection updated" value={formatDateTime(row.balance_updated_at)} /></div>
        <SectionHeading title="Recent account activity" description="Running normal balance is computed from posted journal lines." />
        <DataTable loading={activity.loading} error={activity.error} rows={activity.data?.items || []} rowKey="ledger_entry_id" emptyTitle="No posted activity" columns={[
          { key: 'transaction_ref', label: 'Transaction', render: (value) => <span className="mono">{value}</span> },
          { key: 'entry_side', label: 'Side', render: (value) => titleCase(value) },
          { key: 'amount', label: 'Entry', numeric: true, render: (value, item) => formatMoney(value, item.currency_code) },
          { key: 'running_normal_balance', label: 'Running balance', numeric: true, render: (value, item) => formatMoney(value, item.currency_code) },
          { key: 'posted_at', label: 'Posted', render: (value) => formatDateTime(value) },
        ]} />
      </>}
    </aside>
  </div>
}

function Detail({ label, value }) { return <div className="detail-row"><span>{label}</span><strong>{value || '—'}</strong></div> }
