import { useState } from 'react'
import { Outlet } from 'react-router-dom'
import { useDashboardContext } from '../../contexts/DashboardContext.jsx'
import Sidebar from './Sidebar.jsx'
import TopBar from './TopBar.jsx'

export default function AppLayout() {
  const [menuOpen, setMenuOpen] = useState(false)
  const { theme } = useDashboardContext()
  return <div className={`app-shell theme-${theme}`}>
    <Sidebar open={menuOpen} onClose={() => setMenuOpen(false)} />
    <div className="workspace"><TopBar onMenu={() => setMenuOpen(true)} />
      <main className="page-content"><Outlet /></main>
      <footer className="app-footer"><span>LedgerX · Read-only operations console</span><span>Financial records remain in PostgreSQL</span></footer>
    </div>
  </div>
}
