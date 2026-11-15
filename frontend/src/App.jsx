import { lazy, Suspense } from 'react'
import { Navigate, Outlet, Route, Routes } from 'react-router-dom'
import { AlertCircle } from 'lucide-react'
import AppLayout from './components/layout/AppLayout.jsx'
import ErrorBoundary from './components/ui/ErrorBoundary.jsx'
import { LoadingState } from './components/ui/DataState.jsx'
import { DashboardProvider } from './contexts/DashboardContext.jsx'
import { useAuth } from './contexts/AuthContext.jsx'
import AuthPage from './pages/AuthPage.jsx'
import LandingPage from './pages/LandingPage.jsx'
import WorkspaceOnboarding from './pages/WorkspaceOnboarding.jsx'
import WorkspaceReady from './pages/WorkspaceReady.jsx'
import { AuthCallback } from './pages/AuthCallback.jsx'

const Overview = lazy(() => import('./pages/Overview.jsx'))
const Transactions = lazy(() => import('./pages/Transactions.jsx'))
const Accounts = lazy(() => import('./pages/Accounts.jsx'))
const LedgerExplorer = lazy(() => import('./pages/LedgerExplorer.jsx'))
const Refunds = lazy(() => import('./pages/Refunds.jsx'))
const Settlements = lazy(() => import('./pages/Settlements.jsx'))
const Reconciliation = lazy(() => import('./pages/Reconciliation.jsx'))
const IntegrityMonitor = lazy(() => import('./pages/IntegrityMonitor.jsx'))

export default function App() {
  return <ErrorBoundary>
    <Suspense fallback={<div className="route-loading"><LoadingState label="Opening LedgerX" /></div>}>
      <Routes>
        <Route path="/" element={<LandingPage />} />
        <Route path="/login" element={<AuthPage mode="login" />} />
        <Route path="/signup" element={<AuthPage mode="signup" />} />
        <Route path="/auth/callback" element={<AuthCallback />} />
        <Route element={<RequireAuth />}>
          <Route path="/onboarding" element={<WorkspaceOnboarding />} />
          <Route path="/workspace" element={<WorkspaceReady />} />
        </Route>
        <Route element={<LocalOperationsOnly />}>
          <Route path="/operations" element={<DashboardProvider><AppLayout /></DashboardProvider>}>
            <Route index element={<Overview />} />
            <Route path="transactions" element={<Transactions />} />
            <Route path="accounts" element={<Accounts />} />
            <Route path="ledger" element={<LedgerExplorer />} />
            <Route path="refunds" element={<Refunds />} />
            <Route path="settlements" element={<Settlements />} />
            <Route path="reconciliation" element={<Reconciliation />} />
            <Route path="integrity" element={<IntegrityMonitor />} />
            <Route path="not-found" element={<NotFound />} />
            <Route path="*" element={<Navigate to="/operations/not-found" replace />} />
          </Route>
        </Route>
        <Route path="*" element={<NotFound />} />
      </Routes>
    </Suspense>
  </ErrorBoundary>
}

function RequireAuth() {
  const { user, loading, configError } = useAuth()
  if (loading) return <div className="route-loading"><LoadingState label="Checking your session" /></div>
  if (configError) return <AuthPage mode="login" />
  if (!user) return <Navigate to="/login" replace />
  return <Outlet />
}

function LocalOperationsOnly() {
  return import.meta.env.DEV ? <Outlet /> : <Navigate to="/" replace />
}

function NotFound() {
  return <div className="public-shell"><section className="not-found"><span><AlertCircle size={22} /></span><h2>This page is not available</h2><p>Return to LedgerX to continue.</p><a className="button-primary" href="/">Back to LedgerX</a></section></div>
}
