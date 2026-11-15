import { Check, LogOut, ShieldCheck } from 'lucide-react'
import { Link, Navigate, useLocation, useNavigate } from 'react-router-dom'
import { useAuth } from '../contexts/AuthContext.jsx'

export default function WorkspaceReady() {
  const { state } = useLocation()
  const { supabase, user } = useAuth()
  const navigate = useNavigate()
  const workspace = state?.workspace

  if (!workspace) return <Navigate to="/onboarding" replace />

  async function signOut() {
    await supabase?.auth.signOut()
    navigate('/', { replace: true })
  }

  return <div className="auth-shell">
    <header className="auth-top"><Link className="public-brand" to="/"><span className="brand-mark">L<span>x</span></span><span>ledger<span>x</span></span></Link><button className="text-button" type="button" onClick={signOut}><LogOut size={15} /> Sign out</button></header>
    <main className="workspace-ready-main">
      <section className="workspace-ready-card">
        <span className="ready-check"><Check size={24} /></span>
        <span className="landing-eyebrow">{state.created ? 'WORKSPACE CREATED' : 'WORKSPACE READY'}</span>
        <h1>{workspace.name}</h1>
        <p>Your {workspace.type} workspace is linked to the signed-in account <strong>{user?.email}</strong>.</p>
        <div className="ready-security"><ShieldCheck size={18} /><span><strong>Access check complete</strong><small>PostgreSQL created an owner membership for this workspace.</small></span></div>
        <div className="workspace-ready-note"><strong>Financial views are being connected.</strong><p>Your workspace is isolated from LedgerX's separate local operator console. No other workspace records are shown here.</p></div>
        <Link to="/" className="button-secondary">Return to LedgerX home</Link>
      </section>
    </main>
    <footer className="auth-footer">LedgerX stores financial records only after you choose to add them.</footer>
  </div>
}
