import { NavLink } from 'react-router-dom'
import { Activity, ArrowLeftRight, BookOpenText, CircleDollarSign, CreditCard, Gauge, GitCompareArrows, Layers3, ShieldCheck, X } from 'lucide-react'

const links = [
  { to: '/', label: 'Overview', icon: Gauge, end: true },
  { to: '/transactions', label: 'Transactions', icon: ArrowLeftRight },
  { to: '/accounts', label: 'Accounts', icon: CreditCard },
  { to: '/ledger', label: 'Ledger explorer', icon: BookOpenText },
  { to: '/refunds', label: 'Refunds & reversals', icon: CircleDollarSign },
  { to: '/settlements', label: 'Settlements', icon: Layers3 },
  { to: '/reconciliation', label: 'Reconciliation', icon: GitCompareArrows },
  { to: '/integrity', label: 'Integrity monitor', icon: ShieldCheck },
]

export default function Sidebar({ open, onClose }) {
  return <>
    <aside className={`sidebar ${open ? 'sidebar-open' : ''}`}>
      <div className="brand-row"><div className="brand-mark">L<span>x</span></div><div className="brand-copy"><strong>ledger<span>x</span></strong><small>FINANCIAL OPERATIONS</small></div>
        <button className="sidebar-close" aria-label="Close menu" onClick={onClose}><X size={18} /></button></div>
      <div className="sidebar-label">WORKSPACE</div>
      <nav aria-label="Main navigation" className="sidebar-nav">
        {links.map(({ to, label, icon: Icon, end }) => <NavLink key={to} to={to} end={end}
          onClick={onClose} className={({ isActive }) => `nav-link ${isActive ? 'nav-active' : ''}`}>
          <Icon size={18} strokeWidth={1.8} /><span>{label}</span>{label === 'Integrity monitor' && <span className="nav-dot" />}
        </NavLink>)}
      </nav>
      <div className="sidebar-bottom"><div className="database-card"><span className="database-orb"><Activity size={15} /></span><div><strong>Ledger database</strong><small>PostgreSQL 17 · local</small></div><i className="live-dot" /></div>
        <div className="sidebar-footnote">Read-only analytics workspace</div></div>
    </aside>
    {open && <button className="mobile-scrim" aria-label="Close navigation" onClick={onClose} />}
  </>
}
