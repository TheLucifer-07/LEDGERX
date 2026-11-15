import { useEffect } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { LoadingState } from '../components/ui/DataState.jsx'
import { useAuth } from '../contexts/AuthContext.jsx'

export function AuthCallback() {
  const { user, loading, configError } = useAuth()
  const navigate = useNavigate()

  useEffect(() => {
    if (loading) return
    if (user) {
      navigate('/onboarding', { replace: true })
      return
    }
    if (!configError) navigate('/login?reason=auth_callback', { replace: true })
  }, [loading, user, configError, navigate])

  if (configError) return <div className="auth-shell"><div className="auth-callback-card"><h1>Authentication is not configured</h1><p>{configError}</p><Link to="/login">Return to sign in</Link></div></div>
  return <div className="auth-shell"><div className="auth-callback-card"><LoadingState label="Confirming your sign-in" /></div></div>
}
