import { useState } from 'react'
import { ShieldAlert, ShieldCheck } from 'lucide-react'
import { useApi } from '../hooks/useApi.js'
import { formatCount, titleCase } from '../utils/format.js'
import Panel from '../components/ui/Panel.jsx'
import SectionHeading from '../components/ui/SectionHeading.jsx'
import StatusBadge from '../components/ui/StatusBadge.jsx'
import DataTable from '../components/tables/DataTable.jsx'

export default function IntegrityMonitor() {
  const [page, setPage] = useState(0)
  const result = useApi('/api/v1/integrity/findings', { page, size: 50 })
  const total = result.data?.total ?? 0
  return <div className="page-stack">
    <div className="page-intro"><div><div className="eyebrow">READ-ONLY DATABASE AUDIT</div><h2>Integrity monitor</h2><p>Inspect current financial invariant findings from the existing LedgerX audit function.</p></div><span className="read-only-tag">NO AUTO-REPAIR</span></div>
    <Panel className={`integrity-state-card ${result.loading ? '' : total === 0 ? 'integrity-clean' : 'integrity-attention'}`}>
      <div className="integrity-state-icon">{total === 0 ? <ShieldCheck size={22} /> : <ShieldAlert size={22} />}</div>
      <div className="integrity-state-copy"><span>Database auditor</span><strong>{result.loading ? 'Running audit…' : result.error ? 'Audit unavailable' : total === 0 ? 'No findings returned' : `${formatCount(total)} finding${total === 1 ? '' : 's'} returned`}</strong>
        <p>The API calls <span className="mono">ledger.audit_integrity()</span> using the read-only dashboard role. It never invokes the balance projection rebuild procedure.</p></div>
      {result.data && <span className="audit-source-tag">LIVE FUNCTION</span>}
    </Panel>
    <Panel className="table-panel"><SectionHeading title="Integrity findings" description="Findings are not repaired automatically. Review the underlying records before taking action through the database workflow." />
      <DataTable loading={result.loading} error={result.error} rows={result.data?.items || []} pagination={result.data} onPageChange={setPage} rowKey="finding_key" emptyTitle="No integrity findings" emptyDescription="The database audit currently returns no findings. This is an actual query result."
        columns={[
          { key: 'finding_type', label: 'Finding', render: (value) => <StatusBadge value={value} tone={['unbalanced_journal', 'currency_mismatch', 'over_refund', 'invalid_refund', 'duplicate_reversal', 'invalid_reversal_header', 'reversal_journal_mismatch', 'invalid_transaction_state', 'projected_negative_wallet', 'ledger_negative_wallet'].includes(value) ? 'bad' : 'warning'} /> },
          { key: 'entity_type', label: 'Record type', render: (value) => titleCase(value) },
          { key: 'entity_id', label: 'Record ID', render: (value) => <span className="mono">{value}</span> },
          { key: 'details', label: 'Auditor details', render: (value) => <pre className="json-cell">{prettyJson(value)}</pre> },
        ]} />
    </Panel>
    <div className="warning-note"><ShieldAlert size={16} /><span>Audit reads may scan ledger and projection data. Large datasets can take longer; use refresh to request a new current result.</span></div>
  </div>
}

function prettyJson(value) {
  if (!value) return '—'
  try { return JSON.stringify(JSON.parse(value), null, 2) } catch { return value }
}
