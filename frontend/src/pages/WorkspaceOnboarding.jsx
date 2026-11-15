import { useState } from 'react'
import { ArrowRight, BriefcaseBusiness, Check, GraduationCap, House, UserRound } from 'lucide-react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '../contexts/AuthContext.jsx'

const types = [
  { value: 'student', label: 'Student', detail: 'Allowance, stipend, school costs and savings.', Icon: GraduationCap },
  { value: 'personal', label: 'Personal', detail: 'Your income, spending and plans.', Icon: UserRound },
  { value: 'family', label: 'Family', detail: 'Shared household records and contributions.', Icon: House },
  { value: 'business', label: 'Small business', detail: 'Business income, costs and counterparties.', Icon: BriefcaseBusiness },
]

export default function WorkspaceOnboarding() {
  const { supabase, user, configError } = useAuth()
  const navigate = useNavigate()
  const [workspaceType, setWorkspaceType] = useState('personal')
  const [workspaceName, setWorkspaceName] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  async function createWorkspace(event) {
    event.preventDefault()
    setError('')
    if (!supabase || !user) return
    setBusy(true)
    try {
      const { data: { session }, error: sessionError } = await supabase.auth.getSession()
      if (sessionError || !session?.access_token) throw new Error('Your sign-in session has expired. Sign in again to continue.')
      const response = await fetch('/api/v1/workspaces/bootstrap', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${session.access_token}` },
        body: JSON.stringify({ workspace_type: workspaceType, workspace_name: workspaceName.trim() }),
      })
      const result = await response.json().catch(() => ({}))
      if (!response.ok) throw new Error(result.message || 'Workspace setup is unavailable. Check the API configuration and try again.')
      navigate('/workspace', { replace: true, state: { workspace: result.workspace, created: result.created } })
    } catch (requestError) {
      setError(requestError.message || 'Workspace setup could not be completed.')
    } finally {
      setBusy(false)
    }
  }

  async function signOut() {
    await supabase?.auth.signOut()
    navigate('/', { replace: true })
  }

  return <div className="auth-shell">
    <header className="auth-top"><Link className="public-brand" to="/"><span className="brand-mark">L<span>x</span></span><span>ledger<span>x</span></span></Link><button className="text-button" type="button" onClick={signOut}>Sign out</button></header>
    <main className="onboarding-main">
      <div className="onboarding-progress"><span>01</span><i /><b>YOUR WORKSPACE</b></div>
      <section className="onboarding-card">
        <span className="landing-eyebrow">A PRIVATE STARTING POINT</span>
        <h1>What are you keeping track of?</h1>
        <p className="onboarding-intro">Choose a workspace that fits. It will belong to your account, and you can add members later.</p>
        {configError && <div className="auth-config-message" role="alert"><strong>Authentication setup needed</strong><p>{configError}</p></div>}
        <form onSubmit={createWorkspace}>
          <div className="workspace-choice-grid" role="radiogroup" aria-label="Workspace type">
            {types.map(({ value, label, detail, Icon }) => <button type="button" role="radio" aria-checked={workspaceType === value} className={`workspace-choice ${workspaceType === value ? 'selected' : ''}`} key={value} onClick={() => setWorkspaceType(value)}><span className="choice-icon"><Icon size={18} /></span><strong>{label}</strong><small>{detail}</small>{workspaceType === value && <span className="choice-check"><Check size={13} /></span>}</button>)}
          </div>
          <label className="onboarding-label" htmlFor="workspace-name">Give it a name<input id="workspace-name" required minLength={1} maxLength={120} value={workspaceName} onChange={(event) => setWorkspaceName(event.target.value)} placeholder={workspaceType === 'family' ? 'e.g. Rao household' : workspaceType === 'business' ? 'e.g. Studio records' : workspaceType === 'student' ? 'e.g. College funds' : 'e.g. Personal finances'} /></label>
          <p className="onboarding-privacy">Your email stays with the configured authentication provider. LedgerX stores an internal account ID and workspace membership for access checks.</p>
          {error && <div className="form-error" role="alert">{error}</div>}
          <button className="button-primary auth-submit" type="submit" disabled={busy || !supabase}>{busy ? 'Setting up workspace…' : 'Create private workspace'} <ArrowRight size={16} /></button>
        </form>
      </section>
    </main>
  </div>
}
