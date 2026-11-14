import { AlertCircle, Database, LoaderCircle } from 'lucide-react'

export function LoadingState({ label = 'Loading records' }) {
  return <div className="data-state" role="status"><LoaderCircle className="spin" size={22} /><span>{label}</span></div>
}

export function ErrorState({ message, retry }) {
  return <div className="data-state data-state-error" role="alert">
    <AlertCircle size={22} /><div><strong>Could not load this data</strong><p>{message}</p>
      {retry && <button className="text-button" onClick={retry}>Try again</button>}</div>
  </div>
}

export function EmptyState({ title = 'No records yet', description = 'There are no matching records in the database.' }) {
  return <div className="data-state"><Database size={22} /><div><strong>{title}</strong><p>{description}</p></div></div>
}
