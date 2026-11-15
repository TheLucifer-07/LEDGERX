import { ChevronLeft, ChevronRight } from 'lucide-react'
import { formatCount } from '../../utils/format.js'
import { EmptyState, ErrorState, LoadingState } from '../ui/DataState.jsx'

export default function DataTable({ columns, rows = [], loading, error, onRetry, pagination,
  onPageChange, onRowClick, emptyTitle, emptyDescription, rowKey = 'id' }) {
  if (loading) return <LoadingState />
  if (error) return <ErrorState message={error} retry={onRetry} />
  if (!rows.length) return <EmptyState title={emptyTitle} description={emptyDescription} />
  return <>
    <div className="table-scroll"><table><thead><tr>{columns.map((column) =>
      <th key={column.key} className={column.numeric ? 'numeric' : ''}>{column.label}</th>)}</tr></thead>
      <tbody>{rows.map((row, index) => <tr key={row[rowKey] ?? index}
        className={onRowClick ? 'clickable-row' : ''} onClick={() => onRowClick?.(row)}>
        {columns.map((column) => <td key={column.key} className={column.numeric ? 'numeric' : ''}>
          {column.render ? column.render(row[column.key], row) : (row[column.key] ?? '—')}
        </td>)}
      </tr>)}</tbody></table></div>
    {pagination && <div className="table-footer">
      <span>Showing {pagination.total === 0 ? 0 : pagination.page * pagination.size + 1}–{Math.min((pagination.page + 1) * pagination.size, pagination.total)} of {formatCount(pagination.total)}</span>
      <div className="pagination-actions">
        <button aria-label="Previous page" disabled={pagination.page <= 0} onClick={() => onPageChange(pagination.page - 1)}><ChevronLeft size={16} /></button>
        <span>Page {pagination.page + 1} of {Math.max(1, pagination.pages)}</span>
        <button aria-label="Next page" disabled={pagination.page + 1 >= pagination.pages} onClick={() => onPageChange(pagination.page + 1)}><ChevronRight size={16} /></button>
      </div>
    </div>}
  </>
}
