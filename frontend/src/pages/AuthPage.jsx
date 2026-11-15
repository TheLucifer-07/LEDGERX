import { useEffect, useState } from 'react'
import { ArrowLeft, ArrowRight, Eye, EyeOff, LockKeyhole } from 'lucide-react'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import { useAuth } from '../contexts/AuthContext.jsx'

export default function AuthPage({ mode }) {
  const isSignup = mode === 'signup'
  const { supabase, user, loading, configError } = useAuth()
  const navigate = useNavigate()
  const location = useLocation()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [adultConfirmed, setAdultConfirmed] = useState(false)
  const [showPassword, setShowPassword] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  useEffect(() => {
    if (!loading && user) navigate('/onboarding', { replace: true })
  }, [loading, user, navigate])

  async function submit(event) {
    event.preventDefault()
    setError('')
    setNotice('')
    if (!supabase) return
    if (isSignup && !adultConfirmed) {
      setError('Confirm that you are 18 or older to create an account.')
      return
    }
    if (isSignup && password.length < 12) {
      setError('Use a password with at least 12 characters.')
      return
    }

    setBusy(true)
    try {
      if (isSignup) {
        const { data, error: authError } = await supabase.auth.signUp({
          email: email.trim().toLowerCase(),
          password,
          options: { emailRedirectTo: `${window.location.origin}/auth/callback` },
        })
        if (authError) throw authError
        if (data.session) navigate('/onboarding', { replace: true })
        else setNotice('Check your email for a confirmation link. After confirming, sign in to set up your workspace.')
      } else {
        const { error: authError } = await supabase.auth.signInWithPassword({
          email: email.trim().toLowerCase(),
          password,
        })
        if (authError) throw authError
        navigate('/onboarding', { replace: true })
      }
    } catch (authError) {
      setError(authError?.message || 'Sign-in could not be completed. Please try again.')
    } finally {
      setBusy(false)
    }
  }

  async function continueWithGoogle() {
    setError('')
    if (isSignup && !adultConfirmed) {
      setError('Confirm that you are 18 or older to create an account.')
      return
    }
    if (!supabase) return
    setBusy(true)
    const { error: authError } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo: `${window.location.origin}/auth/callback` },
    })
    if (authError) {
      setError(authError.message || 'Google sign-in could not be started.')
      setBusy(false)
    }
  }

  return <div className="auth-shell">
    <header className="auth-top"><Link className="public-brand" to="/"><span className="brand-mark">L<span>x</span></span><span>ledger<span>x</span></span></Link><Link className="back-link" to="/"><ArrowLeft size={15} /> Back to LedgerX</Link></header>
    <main className="auth-main">
      <section className="auth-card" aria-labelledby="auth-heading">
        <div className="auth-overline"><LockKeyhole size={14} /> PRIVATE WORKSPACE ACCESS</div>
        <h1 id="auth-heading">{isSignup ? 'Create your account' : 'Welcome back'}</h1>
        <p className="auth-subtitle">{isSignup ? 'Start with a private workspace for your records.' : 'Sign in to continue to your workspace.'}</p>

        {configError ? <div className="auth-config-message" role="status"><strong>Authentication setup needed</strong><p>{configError}</p><p>The browser uses a Supabase publishable key. Keep database credentials on the server.</p></div> : <>
          {location.search.includes('auth_callback') && <div className="form-notice" role="status">Your sign-in link could not be confirmed. Try signing in again.</div>}
          <button type="button" className="google-button" onClick={continueWithGoogle} disabled={busy || (isSignup && !adultConfirmed)}><GoogleMark /> Continue with Google</button>
          <div className="auth-divider"><span />or use email<span /></div>
          <form className="auth-form" onSubmit={submit}>
            <label>Email address<input autoComplete="email" type="email" name="email" required maxLength={254} value={email} onChange={(event) => setEmail(event.target.value)} placeholder="you@example.com" /></label>
            <label>Password<span className="password-input"><input autoComplete={isSignup ? 'new-password' : 'current-password'} type={showPassword ? 'text' : 'password'} name="password" required minLength={isSignup ? 12 : 1} value={password} onChange={(event) => setPassword(event.target.value)} placeholder={isSignup ? 'At least 12 characters' : 'Your password'} /><button type="button" aria-label={showPassword ? 'Hide password' : 'Show password'} onClick={() => setShowPassword((value) => !value)}>{showPassword ? <EyeOff size={17} /> : <Eye size={17} />}</button></span></label>
            {isSignup && <label className="adult-check"><input type="checkbox" checked={adultConfirmed} onChange={(event) => setAdultConfirmed(event.target.checked)} /><span>I confirm that I am 18 years of age or older.</span></label>}
            {error && <div className="form-error" role="alert">{error}</div>}
            {notice && <div className="form-notice" role="status">{notice}</div>}
            <button type="submit" className="button-primary auth-submit" disabled={busy || (isSignup && !adultConfirmed)}>{busy ? 'Please wait…' : isSignup ? 'Create account' : 'Sign in'} <ArrowRight size={16} /></button>
          </form>
        </>}
        <div className="auth-switch">{isSignup ? <>Already have an account? <Link to="/login">Sign in</Link></> : <>New to LedgerX? <Link to="/signup">Create an account</Link></>}</div>
        <p className="auth-footnote">Do not enter card numbers, bank credentials, or other sensitive financial secrets.</p>
      </section>
      <aside className="auth-aside"><span className="auth-aside-icon"><LockKeyhole size={20} /></span><span className="landing-eyebrow">BUILT AROUND ACCOUNTABILITY</span><h2>Keep your financial record in your hands.</h2><p>LedgerX records activity in a PostgreSQL ledger with workspace-level access controls.</p><div><span><i /> Your own workspace</span><span><i /> Exact decimal amounts</span><span><i /> Visible corrections</span></div></aside>
    </main>
    <footer className="auth-footer">LedgerX is a recordkeeping tool. It does not transfer money, provide lending, or hold funds.</footer>
  </div>
}

function GoogleMark() {
  return <svg width="18" height="18" viewBox="0 0 48 48" aria-hidden="true"><path fill="#4285F4" d="M43.6 24.5c0-1.4-.1-2.8-.4-4.1H24v7.8h11a9.4 9.4 0 0 1-4.1 6.2v5.1h6.6c3.9-3.6 6.1-8.8 6.1-15z"/><path fill="#34A853" d="M24 44c5.5 0 10.1-1.8 13.5-4.8l-6.6-5.1c-1.8 1.2-4.1 2-6.9 2-5.3 0-9.9-3.6-11.5-8.4H5.7v5.3A20 20 0 0 0 24 44z"/><path fill="#FBBC05" d="M12.5 27.7a12 12 0 0 1 0-7.4V15H5.7a20 20 0 0 0 0 18z"/><path fill="#EA4335" d="M24 12c3 0 5.7 1 7.8 3.1l5.8-5.8C34.1 6.1 29.5 4 24 4A20 20 0 0 0 5.7 15l6.8 5.3C14.1 15.6 18.7 12 24 12z"/></svg>
}
