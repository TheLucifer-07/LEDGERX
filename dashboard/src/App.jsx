import { lazy, Suspense } from 'react'
import { Navigate, Route, Routes, Link } from 'react-router-dom'
import { AlertCircle } from 'lucide-react'
import AppLayout from './components/layout/AppLayout.jsx'
import ErrorBoundary from './components/ui/ErrorBoundary.jsx'
import { LoadingState } from './components/ui/DataState.jsx'

const Overview = lazy(() => import('./pages/Overview.jsx'))
const Transactions = lazy(() => import('./pages/Transactions.jsx'))
const Accounts = lazy(() => import('./pages/Accounts.jsx'))
const LedgerExplorer = lazy(() => import('./pages/LedgerExplorer.jsx'))
const Refunds = lazy(() => import('./pages/Refunds.jsx'))
const Settlements = lazy(() => import('./pages/Settlements.jsx'))
const Reconciliation = lazy(() => import('./pages/Reconciliation.jsx'))
const IntegrityMonitor = lazy(() => import('./pages/IntegrityMonitor.jsx'))

export default function App() {
  return <ErrorBoundary><Suspense fallback={<div className="route-loading"><LoadingState label="Opening ledger view" /></div>}><Routes><Route element={<AppLayout />}>
    <Route index element={<Overview />} />
    <Route path="transactions" element={<Transactions />} />
    <Route path="accounts" element={<Accounts />} />
    <Route path="ledger" element={<LedgerExplorer />} />
    <Route path="refunds" element={<Refunds />} />
    <Route path="settlements" element={<Settlements />} />
    <Route path="reconciliation" element={<Reconciliation />} />
    <Route path="integrity" element={<IntegrityMonitor />} />
    <Route path="not-found" element={<NotFound />} />
    <Route path="*" element={<Navigate to="/not-found" replace />} />
  </Route></Routes></Suspense></ErrorBoundary>
}

function NotFound() {
  return <div className="not-found"><span><AlertCircle size={22} /></span><h2>This view is not available</h2><p>Use the navigation to return to LedgerX records.</p><Link to="/">Back to overview</Link></div>
}
