import { HttpError } from '../utils/http-error.js'

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function createWorkspaceContextHandler({ pool, verifyAccessToken }) {
  return async function workspaceContext(request, response, next) {
    if (!pool || !verifyAccessToken) {
      return next(new HttpError(503, 'workspace_auth_unavailable', 'Authenticated workspace access is not configured.'))
    }

    let auth
    try {
      auth = await verifyAccessToken(request)
    } catch (error) {
      return next(error)
    }

    const workspaceId = request.get('x-ledgerx-workspace-id')
    if (!uuidPattern.test(workspaceId ?? '')) {
      return next(new HttpError(400, 'workspace_id_required', 'A valid X-LedgerX-Workspace-ID header is required.'))
    }

    let client
    let transactionOpen = false
    try {
      client = await pool.connect()
      await client.query('BEGIN READ ONLY')
      transactionOpen = true
      const result = await client.query(
        'SELECT user_id, membership_role FROM ledger.set_request_context($1::uuid, $2::uuid)',
        [auth.subject, workspaceId],
      )
      const membership = result.rows[0]
      if (!membership) {
        throw new HttpError(403, 'workspace_access_denied', 'You do not have access to this workspace.')
      }
      await client.query('COMMIT')
      transactionOpen = false
      response.json({
        user_id: membership.user_id,
        workspace_id: workspaceId,
        role: membership.membership_role,
      })
    } catch (error) {
      if (transactionOpen && client) {
        try {
          await client.query('ROLLBACK')
        } catch {
          // Preserve the original failure; releasing the connection discards its session state.
        }
      }
      if (error?.code === '42501') {
        return next(new HttpError(403, 'workspace_access_denied', 'You do not have access to this workspace.'))
      }
      if (error instanceof HttpError) return next(error)
      return next(new HttpError(503, 'workspace_context_unavailable', 'Workspace access is temporarily unavailable.'))
    } finally {
      client?.release()
    }
  }
}
