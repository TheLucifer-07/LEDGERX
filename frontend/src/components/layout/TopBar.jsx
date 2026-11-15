import { useMemo, useState } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { CalendarDays, ChevronDown, Menu, Moon, RefreshCw, Search, Sun } from 'lucide-react'
import { useDashboardContext } from '../../contexts/DashboardContext.jsx'
import { useApi } from '../../hooks/useApi.js'
import { formatDateTime } from '../../utils/format.js'

const sections = {
  '/operations': ['Overview', 'Local operator / Overview'], '/operations/transactions': ['Transactions', 'Local operator / Activity'],
  '/operations/accounts': ['Accounts', 'Local operator / Customers'], '/operations/ledger': ['Ledger explorer', 'Local operator / Accounting'],
  '/operations/refunds': ['Refunds & reversals', 'Local operator / Adjustments'], '/operations/settlements': ['Settlements', 'Local operator / External records'],
  '/operations/reconciliation': ['Reconciliation', 'Local operator / Matching'], '/operations/integrity': ['Integrity monitor', 'Local operator / Controls'],
}

export default function TopBar({ onMenu }) {
  const location = useLocation()
  const navigate = useNavigate()
  const { period, setPeriod, refresh, theme, toggleTheme } = useDashboardContext()
  const health = useApi('/api/v1/health')
  const [term, setTerm] = useState('')
  const [refreshing, setRefreshing] = useState(false)
  const [title, crumb] = sections[location.pathname] || ['LedgerX', 'Workspace']
  const refreshedAt = useMemo(() => health.updatedAt, [health.updatedAt])

  function submitSearch(event) {
    event.preventDefault()
    if (term.trim()) navigate(`/operations/transactions?search=${encodeURIComponent(term.trim())}`)
  }

  async function handleRefresh() {
    setRefreshing(true)
    refresh()
    window.setTimeout(() => setRefreshing(false), 500)
  }

  return <header className="topbar">
    <div className="topbar-title"><button className="menu-button" aria-label="Open navigation" onClick={onMenu}><Menu size={21} /></button>
      <div><div className="breadcrumbs">{crumb}</div><h1>{title}</h1></div></div>
    <div className="topbar-controls">
      <form className="global-search" onSubmit={submitSearch}><Search size={16} /><input aria-label="Search transactions" placeholder="Search references or accounts" value={term} onChange={(event) => setTerm(event.target.value)} /><kbd>↵</kbd></form>
      <label className="period-select"><CalendarDays size={15} /><select aria-label="Date range" value={period} onChange={(event) => setPeriod(event.target.value)}>
        <option value="7d">Last 7 days</option><option value="30d">Last 30 days</option><option value="90d">Last 90 days</option><option value="all">All time</option>
      </select><ChevronDown size={13} /></label>
      <div className={`connection-pill ${health.data?.status === 'ok' ? 'connected' : 'disconnected'}`} title={health.data?.database_role ? `Connected as ${health.data.database_role}` : health.error || 'Checking database'}>
        <i />{health.data?.status === 'ok' ? 'Database connected' : health.loading ? 'Connecting' : 'Database offline'}
      </div>
      <button className={`icon-button ${refreshing ? 'spinning' : ''}`} aria-label="Refresh data" title={refreshedAt ? `Updated ${formatDateTime(refreshedAt)}` : 'Refresh data'} onClick={handleRefresh}><RefreshCw size={16} /></button>
      <button className="icon-button theme-toggle" aria-label={`Switch to ${theme === 'light' ? 'dark' : 'light'} theme`} title="Switch theme" onClick={toggleTheme}>{theme === 'light' ? <Moon size={17} /> : <Sun size={17} />}</button>
      <div className="avatar" aria-label="Local analyst workspace">LX</div>
    </div>
  </header>
}
