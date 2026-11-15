import { Router } from 'express'
import {
  parseDateRange, parseDirection, parseId, parseOptionalText, parsePage, parseSort,
} from '../utils/query-validation.js'
import { HttpError } from '../utils/http-error.js'

export function createV1Router(reads, { workspaceContext, workspaceBootstrap } = {}) {
  const router = Router()
  const send = (method, options) => async (request, response) => response.json(await reads[method](options(request)))
  const dates = (request) => parseDateRange(request.query)
  const queryText = (request, name, length) => parseOptionalText(request.query[name], length)
  const page = (request, size = 20) => parsePage(request.query, { size })

  router.get('/health', async (_request, response) => response.json(await reads.health()))
  if (workspaceContext) router.get('/workspace/context', workspaceContext)
  if (workspaceBootstrap) router.post('/workspaces/bootstrap', workspaceBootstrap)
  router.get('/currencies', async (_request, response) => response.json(await reads.currencies()))
  router.get('/dashboard/summary', send('summary', dates))
  router.get('/dashboard/transaction-volume', send('transactionVolume', dates))
  router.get('/dashboard/transaction-distribution', send('transactionDistribution', dates))

  router.get('/transactions', send('transactions', (request) => {
    const paging = page(request)
    const dateRange = dates(request)
    return {
      ...paging,
      ...dateRange,
      search: queryText(request, 'search'),
      status: queryText(request, 'status', 32),
      type: queryText(request, 'type', 32),
      currency: queryText(request, 'currency', 3),
      sort: parseSort(request.query.sort, ['created_at', 'amount', 'status', 'type', 'reference', 'currency'], 'created_at'),
      direction: parseDirection(request.query.direction),
    }
  }))
  router.get('/transactions/:id', async (request, response) => response.json(await reads.transaction(parseId(request.params.id, 'transaction id'))))

  router.get('/accounts', send('accounts', (request) => ({
    ...page(request),
    search: queryText(request, 'search'),
    status: queryText(request, 'status', 32),
    kind: queryText(request, 'kind', 32),
    currency: queryText(request, 'currency', 3),
    sort: parseSort(request.query.sort, ['account_code', 'kind', 'status', 'balance', 'created_at'], 'account_code'),
    direction: parseDirection(request.query.direction, 'asc'),
  })))
  router.get('/accounts/:id', async (request, response) => response.json(await reads.account(parseId(request.params.id, 'account id'))))
  router.get('/accounts/:id/activity', send('accountActivity', (request) => ({
    id: parseId(request.params.id, 'account id'), ...page(request),
  })))

  router.get('/ledger/entries', send('ledgerEntries', (request) => ({
    ...page(request, 25),
    ...dates(request),
    search: queryText(request, 'search'),
    side: queryText(request, 'side', 16),
    currency: queryText(request, 'currency', 3),
  })))
  router.get('/ledger/journals/:id', async (request, response) => response.json(await reads.journal(parseId(request.params.id, 'transaction id'))))
  router.all('/transactions', methodNotAllowed)

  router.get('/refunds', send('refunds', (request) => ({
    ...page(request), search: queryText(request, 'search'), status: queryText(request, 'status', 32),
  })))
  router.get('/settlements', send('settlements', (request) => ({
    ...page(request), search: queryText(request, 'search'), status: queryText(request, 'status', 32),
    currency: queryText(request, 'currency', 3),
  })))
  router.get('/settlements/:id/items', send('settlementItems', (request) => ({
    id: parseId(request.params.id, 'settlement batch id'), ...page(request, 25),
  })))
  router.get('/reconciliation/runs', send('reconciliationRuns', (request) => page(request)))
  router.get('/reconciliation/exceptions', send('reconciliationExceptions', (request) => ({
    ...page(request, 25), type: queryText(request, 'type', 40), search: queryText(request, 'search'),
  })))
  router.get('/reconciliation/unsettled', send('unsettledTransactions', (request) => page(request, 25)))
  router.get('/integrity/findings', send('integrityFindings', (request) => page(request, 25)))

  router.use((_request, _response, next) => next(new HttpError(404, 'not_found', 'The requested API route was not found.')))
  return router
}

function methodNotAllowed(_request, response) {
  response.set('Allow', 'GET')
  response.status(405).json({ error: 'method_not_allowed', message: 'This endpoint is read-only.' })
}
