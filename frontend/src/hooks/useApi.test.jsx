import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import { DashboardProvider } from '../contexts/DashboardContext.jsx'
import { useApi } from './useApi.js'

function ApiText({ path = '/api/v1/health' }) {
  const { data, loading, error } = useApi(path)
  if (loading) return <p>Loading from LedgerX</p>
  if (error) return <p role="alert">{error}</p>
  return <p>{data.status}</p>
}

function renderHarness(path) {
  return render(<DashboardProvider><ApiText path={path} /></DashboardProvider>)
}

describe('useApi', () => {
  afterEach(() => { cleanup(); vi.restoreAllMocks() })

  it('renders actual API response data', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: true, json: async () => ({ status: 'ok' }) }))
    renderHarness('/api/v1/health')
    expect(await screen.findByText('ok')).toBeInTheDocument()
    expect(fetch).toHaveBeenCalledWith('/api/v1/health', expect.objectContaining({ headers: { Accept: 'application/json' } }))
  })

  it('shows the API failure without using fallback data', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false, status: 503, json: async () => ({ message: 'Ledger database offline' }) }))
    renderHarness('/api/v1/health')
    expect(await screen.findByRole('alert')).toHaveTextContent('Ledger database offline')
  })
})
