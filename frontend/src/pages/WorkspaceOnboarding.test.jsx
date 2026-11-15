import { beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { useAuth } from '../contexts/AuthContext.jsx'
import WorkspaceOnboarding from './WorkspaceOnboarding.jsx'

vi.mock('../contexts/AuthContext.jsx', () => ({ useAuth: vi.fn() }))

function WorkspaceResult() {
  const { state } = useLocation()
  return <output data-testid="workspace-result">{state?.workspace?.name}|{String(state?.created)}</output>
}

function renderPage() {
  return render(<MemoryRouter initialEntries={['/onboarding']}>
    <Routes>
      <Route path="/onboarding" element={<WorkspaceOnboarding />} />
      <Route path="/workspace" element={<WorkspaceResult />} />
    </Routes>
  </MemoryRouter>)
}

describe('workspace onboarding', () => {
  let supabase

  beforeEach(() => {
    supabase = { auth: { getSession: vi.fn().mockResolvedValue({ data: { session: { access_token: 'signed-test-token' } }, error: null }), signOut: vi.fn() } }
    useAuth.mockReturnValue({ supabase, user: { email: 'person@example.com' }, configError: null })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: true, json: async () => ({ created: true, workspace: { id: '00000000-0000-4000-8000-000000000002', name: 'College funds', type: 'student' } }) }))
  })

  it('sends the verified session to the real workspace bootstrap route', async () => {
    renderPage()
    fireEvent.click(screen.getByRole('radio', { name: /student/i }))
    fireEvent.change(screen.getByRole('textbox', { name: /give it a name/i }), { target: { value: 'College funds' } })
    fireEvent.click(screen.getByRole('button', { name: /create private workspace/i }))

    await waitFor(() => expect(fetch).toHaveBeenCalledWith('/api/v1/workspaces/bootstrap', expect.objectContaining({
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer signed-test-token' },
      body: JSON.stringify({ workspace_type: 'student', workspace_name: 'College funds' }),
    })))
    expect(await screen.findByTestId('workspace-result')).toHaveTextContent('College funds|true')
  })

  it('shows the API error without pretending setup succeeded', async () => {
    fetch.mockResolvedValue({ ok: false, status: 503, json: async () => ({ message: 'Authenticated workspace access is not configured.' }) })
    renderPage()
    fireEvent.change(screen.getByRole('textbox', { name: /give it a name/i }), { target: { value: 'My records' } })
    fireEvent.click(screen.getByRole('button', { name: /create private workspace/i }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Authenticated workspace access is not configured')
    expect(screen.queryByTestId('workspace-result')).not.toBeInTheDocument()
  })
})
