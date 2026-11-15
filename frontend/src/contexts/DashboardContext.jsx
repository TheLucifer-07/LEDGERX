import { createContext, useCallback, useContext, useMemo, useState } from 'react'

const DashboardContext = createContext(null)

export function DashboardProvider({ children }) {
  const [refreshVersion, setRefreshVersion] = useState(0)
  const [period, setPeriod] = useState('30d')
  const [theme, setTheme] = useState(() => localStorage.getItem('ledgerx-theme') || 'light')
  const refresh = useCallback(() => setRefreshVersion((value) => value + 1), [])
  const toggleTheme = useCallback(() => {
    setTheme((current) => {
      const next = current === 'light' ? 'dark' : 'light'
      localStorage.setItem('ledgerx-theme', next)
      return next
    })
  }, [])
  const value = useMemo(() => ({ refreshVersion, refresh, period, setPeriod, theme, toggleTheme }),
    [refreshVersion, refresh, period, theme, toggleTheme])
  return <DashboardContext.Provider value={value}>{children}</DashboardContext.Provider>
}

export function useDashboardContext() {
  const context = useContext(DashboardContext)
  if (!context) throw new Error('useDashboardContext must be used inside DashboardProvider')
  return context
}
