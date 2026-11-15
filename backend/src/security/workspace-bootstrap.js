import { z } from 'zod'
import { HttpError } from '../utils/http-error.js'

const workspaceInput = z.object({
  workspace_type: z.enum(['student', 'personal', 'family', 'business']),
  workspace_name: z.string().trim().min(1).max(120),
}).strict()

export function createWorkspaceBootstrapHandler({ pool, verifyAccessToken }) {
  return async function bootstrapWorkspace(request, response, next) {
    if (!pool || !verifyAccessToken) {
      return next(new HttpError(503, 'workspace_auth_unavailable', 'Authenticated workspace access is not configured.'))
    }

    let auth
    try {
      auth = await verifyAccessToken(request)
    } catch (error) {
      return next(error)
    }

    const parsed = workspaceInput.safeParse(request.body)
    if (!parsed.success) {
      return next(new HttpError(400, 'invalid_workspace_request', 'Provide a workspace type and a name between 1 and 120 characters.'))
    }

    let client
    let transactionOpen = false
    try {
      client = await pool.connect()
      await client.query('BEGIN READ WRITE')
      transactionOpen = true
      const result = await client.query(
        `SELECT user_id, workspace_id, workspace_type, workspace_name, created
           FROM ledger.bootstrap_workspace($1::uuid, $2::text, $3::text)`,
        [auth.subject, parsed.data.workspace_type, parsed.data.workspace_name],
      )
      const workspace = result.rows[0]
      if (!workspace) throw new Error('workspace bootstrap returned no row')
      await client.query('COMMIT')
      transactionOpen = false
      response.status(workspace.created ? 201 : 200).json({
        user_id: workspace.user_id,
        workspace: {
          id: workspace.workspace_id,
          type: workspace.workspace_type,
          name: workspace.workspace_name,
        },
        created: workspace.created,
      })
    } catch {
      if (transactionOpen && client) {
        try {
          await client.query('ROLLBACK')
        } catch {
          // Preserve a generic response and let pg discard the checked-out session.
        }
      }
      return next(new HttpError(503, 'workspace_bootstrap_unavailable', 'Workspace setup is temporarily unavailable.'))
    } finally {
      client?.release()
    }
  }
}
