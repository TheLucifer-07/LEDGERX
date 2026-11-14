import { useMemo, useState } from 'react'
import { motion } from 'framer-motion'
import { Activity, ArrowUpRight, BadgeCheck, Banknote, Building2, ChartNoAxesCombined, CircleAlert, Layers3 } from 'lucide-react'
import { Area, AreaChart, Bar, BarChart, CartesianGrid, Cell, Pie, PieChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts'
import { useApi } from '../hooks/useApi.js'
import { useDateRange } from '../hooks/useDateRange.js'
import { formatCount, formatDate, formatMoney, formatDateTime, titleCase } from '../utils/format.js'
import KpiCard from '../components/dashboard/KpiCard.jsx'
import DataTable from '../components/tables/DataTable.jsx'
import StatusBadge from '../components/ui/StatusBadge.jsx'
import Panel from '../components/ui/Panel.jsx'
import SectionHeading from '../components/ui/SectionHeading.jsx'
import { EmptyState, ErrorState, LoadingState } from '../components/ui/DataState.jsx'

const ink = ['#71394b', '#b78b5b', '#69736c', '#9a766f', '#8d9091', '#c5aa86']

export default function Overview() {
  const dates = useDateRange()
  const summary = useApi('/api/v1/dashboard/summary', dates)
  const volume = useApi('/api/v1/dashboard/transaction-volume', dates)
  const distribution = useApi('/api/v1/dashboard/transaction-distribution', dates)
  const recent = useApi('/api/v1/transactions', { page: 0, size: 6, sort: 'created_at', direction: 'desc', ...dates })
  const batches = useApi('/api/v1/settlements', { page: 0, size: 4 })
  const exceptions = useApi('/api/v1/reconciliation/exceptions', { page: 0, size: 4 })
  const [currency, setCurrency] = useState('')
  const summaryData = summary.data
  const currencies = [...new Set((volume.data?.items || []).map((item) => item.currency_code))]
  const chosenCurrency = currencies.includes(currency) ? currency : currencies[0]
  const chartData = useMemo(() => {
    const daily = new Map()
    for (const row of volume.data?.items || []) {
      if (row.currency_code !== chosenCurrency) continue
      const key = row.transaction_date
      const entry = daily.get(key) || { date: key, gross_amount: 0, transaction_count: 0 }
      entry.gross_amount += Number(row.gross_amount || 0)
      entry.transaction_count += Number(row.transaction_count || 0)
      daily.set(key, entry)
    }
    return [...daily.values()].sort((a, b) => a.date.localeCompare(b.date))
  }, [volume.data, chosenCurrency])
  const postedVolume = summaryData?.posted_volume_by_currency || []
  const txCount = summaryData?.transactions?.total_transactions
  const postedCount = summaryData?.transactions?.posted_transactions
  const totalAccounts = summaryData?.accounts?.total_accounts
  const activeAccounts = summaryData?.accounts?.active_accounts
  const batchCount = summaryData?.settlements?.total_batches
  const exceptionCount = summaryData?.settlements?.reconciliation_exceptions
  const findingCount = summaryData?.integrity_finding_count
  const errors = [summary, volume, distribution].find((result) => result.error)

  return <motion.div className="page-stack" initial={{ opacity: 0, y: 7 }} animate={{ opacity: 1, y: 0 }}>
    <div className="welcome-row"><div><div className="eyebrow">FINANCIAL CONTROL ROOM</div><h2>Good to see you.</h2><p>Your ledger activity, at a glance.</p></div>
      <div className="data-note"><span className="data-note-icon"><Activity size={16} /></span><span><strong>Live ledger data</strong><small>Refreshed {summary.updatedAt ? formatDateTime(summary.updatedAt) : 'when available'}</small></span></div>
    </div>
    {errors ? <ErrorState message={errors.error} retry={errors.refetch} /> : null}
    <div className="kpi-grid">
      <KpiCard label="Transactions" value={summary.loading ? '—' : formatCount(txCount)} note={`${formatCount(postedCount)} posted in range`} icon={ArrowUpRight} />
      <KpiCard label="Posted volume" value={summary.loading ? '—' : postedVolume.length ? postedVolume.map((row) => `${row.currency_code} ${formatMoney(row.posted_volume, row.currency_code)}`).join(' · ') : 'No posted volume'} note="Kept separate by currency" icon={Banknote} accent />
      <KpiCard label="Active accounts" value={summary.loading ? '—' : formatCount(activeAccounts)} note={`${formatCount(totalAccounts)} total accounts`} icon={Building2} />
      <KpiCard label="Settlement batches" value={summary.loading ? '—' : formatCount(batchCount)} note="External statement batches" icon={Layers3} />
      <KpiCard label="Reconciliation exceptions" value={summary.loading ? '—' : formatCount(exceptionCount)} note="Across latest batch runs" icon={CircleAlert} />
      <KpiCard label="Ledger integrity" value={summary.loading ? '—' : findingCount === 0 ? 'All clear' : `${formatCount(findingCount)} findings`} note={findingCount === 0 ? 'Read-only audit found no issues' : 'Review integrity findings'} icon={findingCount === 0 ? BadgeCheck : CircleAlert} />
    </div>

    <div className="dashboard-grid dashboard-grid-wide">
      <Panel className="chart-panel">
        <SectionHeading title="Transaction volume" description="Posted transaction value by day, in one currency at a time."
          action={<label className="chart-select"><span>Currency</span><select aria-label="Chart currency" value={chosenCurrency || ''} onChange={(event) => setCurrency(event.target.value)} disabled={!currencies.length}><option value="">No data</option>{currencies.map((code) => <option key={code}>{code}</option>)}</select></label>} />
        <div className="chart-legend"><span className="legend-dot" />Gross posted volume {chosenCurrency && <b>{chosenCurrency}</b>}</div>
        <div className="chart-frame chart-main">{volume.loading ? <LoadingState /> : volume.error ? <ErrorState message={volume.error} /> : !chartData.length ? <EmptyState title="No posted activity" description="No posted transaction volume exists for this date range." /> :
          <ResponsiveContainer width="100%" height="100%"><AreaChart data={chartData} margin={{ top: 12, right: 10, left: 0, bottom: 0 }}>
            <defs><linearGradient id="volumeFill" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stopColor="#71394b" stopOpacity={0.2} /><stop offset="96%" stopColor="#71394b" stopOpacity={0.015} /></linearGradient></defs>
            <CartesianGrid strokeDasharray="3 5" vertical={false} stroke="var(--line-soft)" />
            <XAxis dataKey="date" tickFormatter={(value) => formatDate(value, { month: 'short', day: 'numeric' })} axisLine={false} tickLine={false} tick={{ fill: 'var(--muted)', fontSize: 11 }} minTickGap={28} />
            <YAxis tickFormatter={(value) => new Intl.NumberFormat(undefined, { notation: 'compact' }).format(value)} axisLine={false} tickLine={false} tick={{ fill: 'var(--muted)', fontSize: 11 }} width={46} />
            <Tooltip formatter={(value) => formatMoney(value, chosenCurrency)} labelFormatter={(value) => formatDate(value)} contentStyle={{ background: 'var(--panel)', border: '1px solid var(--line)', borderRadius: 12, boxShadow: 'var(--shadow-soft)' }} />
            <Area type="monotone" dataKey="gross_amount" name="Posted volume" stroke="#71394b" strokeWidth={2.4} fill="url(#volumeFill)" activeDot={{ r: 4, fill: '#71394b', strokeWidth: 0 }} />
          </AreaChart></ResponsiveContainer>}
        </div>
      </Panel>
      <Panel className="distribution-panel">
        <SectionHeading title="Transaction mix" description="Current period breakdown." />
        <div className="mix-block"><div className="mix-title">By status</div>
          {distribution.loading ? <LoadingState /> : distribution.error ? <ErrorState message={distribution.error} /> : !distribution.data?.by_status?.length ? <EmptyState /> : <>
            <div className="donut-wrap"><ResponsiveContainer width="100%" height={180}><PieChart><Pie data={distribution.data.by_status} dataKey="transaction_count" nameKey="status" innerRadius={54} outerRadius={76} paddingAngle={3} stroke="none">{distribution.data.by_status.map((row, index) => <Cell key={row.status} fill={ink[index % ink.length]} />)}</Pie><Tooltip formatter={(value) => formatCount(value)} contentStyle={{ background: 'var(--panel)', border: '1px solid var(--line)', borderRadius: 10 }} /></PieChart></ResponsiveContainer><div className="donut-center"><strong>{formatCount(distribution.data.by_status.reduce((total, row) => total + Number(row.transaction_count), 0))}</strong><small>transactions</small></div></div>
            <div className="status-legend">{distribution.data.by_status.map((row, index) => <div key={row.status}><span className="legend-swatch" style={{ backgroundColor: ink[index % ink.length] }} /><span>{titleCase(row.status)}</span><b>{formatCount(row.transaction_count)}</b></div>)}</div>
          </>}
        </div>
        <div className="mix-block mix-types"><div className="mix-title">By transaction type</div>
          {!distribution.data?.by_type?.length ? <span className="muted">No type breakdown available.</span> : <div className="type-bars"><ResponsiveContainer width="100%" height={126}><BarChart data={distribution.data.by_type} layout="vertical" margin={{ top: 2, right: 10, left: 8, bottom: 0 }}><XAxis type="number" hide /><YAxis type="category" dataKey="transaction_type" width={80} tickFormatter={titleCase} axisLine={false} tickLine={false} tick={{ fill: 'var(--muted)', fontSize: 11 }} /><Tooltip formatter={(value) => formatCount(value)} contentStyle={{ background: 'var(--panel)', border: '1px solid var(--line)', borderRadius: 10 }} /><Bar dataKey="transaction_count" fill="#b78b5b" radius={[0, 5, 5, 0]} barSize={11} /></BarChart></ResponsiveContainer></div>}
        </div>
      </Panel>
    </div>

    <div className="dashboard-grid dashboard-grid-lower">
      <Panel className="recent-panel"><SectionHeading title="Recent transactions" description="Latest recorded activity" action={<a className="inline-link" href="/transactions">View all <ArrowUpRight size={14} /></a>} />
        <DataTable loading={recent.loading} error={recent.error} rows={recent.data?.items || []} emptyTitle="No transactions yet" columns={[
          { key: 'transaction_ref', label: 'Reference', render: (value) => <span className="mono strong-text">{value}</span> },
          { key: 'transaction_type', label: 'Type', render: (value) => <span>{titleCase(value)}</span> },
          { key: 'amount', label: 'Amount', numeric: true, render: (value, row) => <span className="amount-text">{formatMoney(value, row.currency_code)}</span> },
          { key: 'status', label: 'Status', render: (value) => <StatusBadge value={value} /> },
          { key: 'created_at', label: 'Created', render: (value) => formatDateTime(value) },
        ]} />
      </Panel>
      <Panel className="side-list-panel"><SectionHeading title="Settlement watch" description="Latest external statement batches" />
        <MiniRecords state={batches} kind="settlements" />
        <div className="mini-divider" />
        <SectionHeading title="Open exceptions" description="Items needing reconciliation attention" />
        <MiniRecords state={exceptions} kind="exceptions" />
      </Panel>
    </div>
    <div className="footnote-line"><ChartNoAxesCombined size={14} /> Figures come directly from LedgerX PostgreSQL queries. Monetary totals remain grouped by currency.</div>
  </motion.div>
}

function MiniRecords({ state, kind }) {
  if (state.loading) return <LoadingState label="Loading records" />
  if (state.error) return <ErrorState message={state.error} />
  const items = state.data?.items || []
  if (!items.length) return <EmptyState title={kind === 'settlements' ? 'No batches imported' : 'No exceptions recorded'} description={kind === 'settlements' ? 'Settlement batches will appear when statement data is imported.' : 'The latest reconciliation runs have no listed exceptions.'} />
  return <div className="mini-record-list">{items.map((item) => kind === 'settlements' ? <div className="mini-record" key={item.settlement_batch_id}>
    <div className="mini-record-symbol"><Layers3 size={15} /></div><div className="mini-record-main"><strong>{item.external_batch_ref}</strong><small>{formatDate(item.statement_date)} · {item.currency_code}</small></div>
    <div className="mini-record-end"><b>{formatMoney(item.external_gross_total, item.currency_code)}</b><StatusBadge value={item.status} /></div>
  </div> : <div className="mini-record" key={item.reconciliation_result_id}>
    <div className="mini-record-symbol mini-record-alert"><CircleAlert size={15} /></div><div className="mini-record-main"><strong>{titleCase(item.result_type)}</strong><small>{item.external_batch_ref} · {item.transaction_ref || item.external_ref || 'Statement item'}</small></div>
    <div className="mini-record-end"><StatusBadge value={item.result_type} /></div>
  </div>)}</div>
}
