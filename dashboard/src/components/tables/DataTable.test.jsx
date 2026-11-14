import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import DataTable from './DataTable.jsx'

const columns = [{ key: 'reference', label: 'Reference' }]

describe('DataTable', () => {
  it('shows a loading state', () => {
    render(<DataTable columns={columns} loading />)
    expect(screen.getByRole('status')).toHaveTextContent('Loading records')
  })

  it('shows the API error message', () => {
    render(<DataTable columns={columns} error="Database unavailable" />)
    expect(screen.getByRole('alert')).toHaveTextContent('Database unavailable')
  })

  it('shows an honest empty state', () => {
    render(<DataTable columns={columns} rows={[]} />)
    expect(screen.getByText('No records yet')).toBeInTheDocument()
  })

  it('renders real rows and invokes pagination', () => {
    const onPageChange = vi.fn()
    render(<DataTable columns={columns} rows={[{ id: 3, reference: 'TX-104' }]} rowKey="id"
      pagination={{ page: 0, size: 1, total: 2, pages: 2 }} onPageChange={onPageChange} />)
    expect(screen.getByText('TX-104')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Next page' }))
    expect(onPageChange).toHaveBeenCalledWith(1)
  })
})
