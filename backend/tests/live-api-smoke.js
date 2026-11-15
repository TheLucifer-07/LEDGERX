const baseUrl = (process.env.API_BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '')
const paths = [
  '/health/live',
  '/health/ready',
  '/api/v1/health',
  '/api/v1/currencies',
  '/api/v1/dashboard/summary?from=2026-01-01&to=2026-12-31',
  '/api/v1/dashboard/transaction-volume?from=2026-01-01&to=2026-12-31',
  '/api/v1/dashboard/transaction-distribution?from=2026-01-01&to=2026-12-31',
  '/api/v1/transactions?page=0&size=10&sort=amount&direction=asc',
  '/api/v1/accounts?page=0&size=10&sort=balance',
  '/api/v1/ledger/entries?page=0&size=10',
  '/api/v1/refunds?page=0&size=10',
  '/api/v1/settlements?page=0&size=10',
  '/api/v1/reconciliation/runs?page=0&size=10',
  '/api/v1/reconciliation/exceptions?page=0&size=10',
  '/api/v1/reconciliation/unsettled?page=0&size=10',
  '/api/v1/integrity/findings?page=0&size=10',
]

let failures = 0
const bodies = new Map()
for (const path of paths) {
  const response = await fetch(`${baseUrl}${path}`)
  const ok = response.status === 200
  console.log(`${ok ? 'PASS' : 'FAIL'} ${response.status} GET ${path}`)
  if (!ok) failures += 1
  if (ok && path.startsWith('/api/v1/')) bodies.set(path.split('?')[0], await response.json())
}

const transactions = bodies.get('/api/v1/transactions')?.items ?? []
const accounts = bodies.get('/api/v1/accounts')?.items ?? []
const settlements = bodies.get('/api/v1/settlements')?.items ?? []
const dynamicPaths = []
if (transactions[0]?.transaction_id) {
  const id = transactions[0].transaction_id
  dynamicPaths.push(`/api/v1/transactions/${id}`, `/api/v1/ledger/journals/${id}`)
} else console.log('SKIP detail/journal routes: database has no transaction to inspect.')
if (accounts[0]?.account_id) {
  const id = accounts[0].account_id
  dynamicPaths.push(`/api/v1/accounts/${id}`, `/api/v1/accounts/${id}/activity?page=0&size=10`)
} else console.log('SKIP account detail/activity routes: database has no account to inspect.')
if (settlements[0]?.settlement_batch_id) {
  dynamicPaths.push(`/api/v1/settlements/${settlements[0].settlement_batch_id}/items?page=0&size=10`)
} else console.log('SKIP settlement item route: database has no settlement batch to inspect.')

for (const path of dynamicPaths) {
  const response = await fetch(`${baseUrl}${path}`)
  const ok = response.status === 200
  console.log(`${ok ? 'PASS' : 'FAIL'} ${response.status} GET ${path}`)
  if (!ok) failures += 1
  if (ok && path.includes('/ledger/journals/')) {
    const result = await response.json()
    const balanced = result.totals?.balanced === true
    console.log(`${balanced ? 'PASS' : 'FAIL'} journal balancing summary`)
    if (!balanced) failures += 1
  }
}

for (const [path, method, expectedStatus] of [
  ['/api/v1/dashboard/summary?from=not-a-date&to=2026-12-31', 'GET', 400],
  ['/api/v1/transactions?page=-1', 'GET', 400],
  ['/api/v1/transactions', 'POST', 405],
]) {
  const response = await fetch(`${baseUrl}${path}`, { method, headers: { 'content-type': 'application/json' }, body: method === 'POST' ? '{}' : undefined })
  const ok = response.status === expectedStatus
  console.log(`${ok ? 'PASS' : 'FAIL'} ${response.status} ${method} ${path}`)
  if (!ok) failures += 1
}

if (failures) process.exitCode = 1
else console.log(`Passed ${paths.length + dynamicPaths.length + 3} live API checks.`)
