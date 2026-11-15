import { useEffect, useMemo, useState } from 'react'
import { useDashboardContext } from '../contexts/DashboardContext.jsx'

const apiBaseUrl = (import.meta.env.VITE_API_BASE_URL || '').replace(/\/$/, '')

export function useApi(path, params = {}) {
  const { refreshVersion } = useDashboardContext()
  const query = useMemo(() => {
    const search = new URLSearchParams()
    Object.entries(params).forEach(([key, value]) => {
      if (value !== undefined && value !== null && value !== '') search.set(key, String(value))
    })
    return search.toString()
  // A serialized key keeps callers free to provide a fresh object literal.
  }, [JSON.stringify(params)])
  const url = `${apiBaseUrl}${query ? `${path}?${query}` : path}`
  const [state, setState] = useState({ data: null, loading: true, error: null, updatedAt: null })

  useEffect(() => {
    const controller = new AbortController()
    setState((current) => ({ ...current, loading: true, error: null }))
    fetch(url, { headers: { Accept: 'application/json' }, signal: controller.signal })
      .then(async (response) => {
        const body = await response.json().catch(() => ({}))
        if (!response.ok) throw new Error(body.message || `Request failed (${response.status})`)
        return body
      })
      .then((data) => setState({ data, loading: false, error: null, updatedAt: new Date() }))
      .catch((error) => {
        if (error.name !== 'AbortError') setState({ data: null, loading: false, error: error.message, updatedAt: null })
      })
    return () => controller.abort()
  }, [url, refreshVersion])

  return state
}
