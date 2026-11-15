import { beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { useAuth } from '../contexts/AuthContext.jsx'
import AuthPage from './AuthPage.jsx'

vi.mock('../contexts/AuthContext.jsx', () => ({ useAuth: vi.fn() }))

function CurrentPath() {
  return <output data-testid="current-path">{useLocation().pathname}</output>
}

function renderAuth(mode) {
  return render(<MemoryRouter initialEntries={[mode === 'signup' ? '/signup' : '/login']}>
    <Routes>
      <Route path="/login" element={<><AuthPage mode="login" /><CurrentPath /></>} />
      <Route path="/signup" element={<><AuthPage mode="signup" /><CurrentPath /></>} />
      <Route path="/onboarding" element={<><p>Workspace setup</p><CurrentPath /></>} />
    </Routes>
  </MemoryRouter>)
}

describe('account access', () => {
  let auth

  beforeEach(() => {
    auth = {
      signUp: vi.fn().mockResolvedValue({ data: { session: null }, error: null }),
      signInWithPassword: vi.fn().mockResolvedValue({ error: null }),
      signInWithOAuth: vi.fn().mockResolvedValue({ error: null }),
    }
    useAuth.mockReturnValue({ supabase: { auth }, user: null, loading: false, configError: null })
  })

  it('signs in with normalized email and routes to workspace setup', async () => {
    renderAuth('login')
    fireEvent.change(screen.getByRole('textbox', { name: /email address/i }), { target: { value: '  Person@Example.com ' } })
    fireEvent.change(screen.getByLabelText('Password'), { target: { value: 'correct horse battery staple' } })
    fireEvent.click(screen.getByRole('button', { name: /sign in/i }))

    await waitFor(() => expect(auth.signInWithPassword).toHaveBeenCalledWith({
      email: 'person@example.com', password: 'correct horse battery staple',
    }))
    await waitFor(() => expect(screen.getByTestId('current-path')).toHaveTextContent('/onboarding'))
  })

  it('requires the adult attestation and a longer password for signup', async () => {
    renderAuth('signup')
    const submit = screen.getByRole('button', { name: /create account/i })
    expect(submit).toBeDisabled()
    fireEvent.change(screen.getByRole('textbox', { name: /email address/i }), { target: { value: 'student@example.com' } })
    fireEvent.change(screen.getByLabelText('Password'), { target: { value: 'short' } })
    fireEvent.click(screen.getByRole('checkbox', { name: /18 years of age or older/i }))
    fireEvent.click(submit)
    expect(await screen.findByRole('alert')).toHaveTextContent('at least 12 characters')
    expect(auth.signUp).not.toHaveBeenCalled()
  })

  it('creates an email account only after the adult check and requests email confirmation', async () => {
    renderAuth('signup')
    fireEvent.change(screen.getByRole('textbox', { name: /email address/i }), { target: { value: 'Person@Example.com' } })
    fireEvent.change(screen.getByLabelText('Password'), { target: { value: 'a-long-enough-password' } })
    fireEvent.click(screen.getByRole('checkbox', { name: /18 years of age or older/i }))
    fireEvent.click(screen.getByRole('button', { name: /create account/i }))

    await waitFor(() => expect(auth.signUp).toHaveBeenCalledWith({
      email: 'person@example.com',
      password: 'a-long-enough-password',
      options: { emailRedirectTo: `${window.location.origin}/auth/callback` },
    }))
    expect(await screen.findByText(/check your email for a confirmation link/i)).toBeInTheDocument()
  })

  it('starts Google OAuth only after the adult check on signup', async () => {
    renderAuth('signup')
    const button = screen.getByRole('button', { name: /continue with google/i })
    expect(button).toBeDisabled()
    fireEvent.click(screen.getByRole('checkbox', { name: /18 years of age or older/i }))
    fireEvent.click(button)
    await waitFor(() => expect(auth.signInWithOAuth).toHaveBeenCalledWith({
      provider: 'google', options: { redirectTo: `${window.location.origin}/auth/callback` },
    }))
  })

  it('explains missing configuration instead of simulating account access', () => {
    useAuth.mockReturnValue({ supabase: null, user: null, loading: false, configError: 'Authentication is not configured.' })
    renderAuth('login')
    expect(screen.getByText('Authentication setup needed')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /continue with google/i })).not.toBeInTheDocument()
  })
})
