import { describe, expect, it } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import Sidebar from './Sidebar.jsx'

function CurrentPath() {
  const location = useLocation()
  return <output>{location.pathname}</output>
}

describe('Sidebar navigation', () => {
  it('provides working links to each data view', () => {
    render(<MemoryRouter initialEntries={['/']}><Sidebar onClose={() => {}} /><Routes><Route path="*" element={<CurrentPath />} /></Routes></MemoryRouter>)
    const views = [
      ['Overview', '/'], ['Transactions', '/transactions'], ['Accounts', '/accounts'],
      ['Ledger explorer', '/ledger'], ['Refunds & reversals', '/refunds'],
      ['Settlements', '/settlements'], ['Reconciliation', '/reconciliation'],
      ['Integrity monitor', '/integrity'],
    ]
    for (const [label, route] of views) {
      fireEvent.click(screen.getByRole('link', { name: label }))
      expect(screen.getByText(route)).toBeInTheDocument()
    }
  })
})
