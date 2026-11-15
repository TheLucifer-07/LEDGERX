import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import LandingPage from './LandingPage.jsx'

describe('public landing page', () => {
  it('explains the actual ledger foundation and links to working account routes', () => {
    render(<MemoryRouter><LandingPage /></MemoryRouter>)
    expect(screen.getByRole('heading', { name: /see your money clearly/i })).toBeInTheDocument()
    expect(screen.getByText(/equal debits and credits/i)).toBeInTheDocument()
    expect(screen.getByRole('link', { name: /create your workspace/i })).toHaveAttribute('href', '/signup')
    expect(screen.getByRole('link', { name: /sign in/i })).toHaveAttribute('href', '/login')
    expect(screen.queryByText(/\$[0-9]|₹\s?[0-9]/)).not.toBeInTheDocument()
  })
})
