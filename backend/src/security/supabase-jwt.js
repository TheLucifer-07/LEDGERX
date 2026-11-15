import { verifyAuth } from '@supabase/server/core'
import { HttpError } from '../utils/http-error.js'

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function createSupabaseAccessTokenVerifier({
  supabaseUrl,
  jwksUrl,
  jwks,
  verify = verifyAuth,
}) {
  const issuer = `${supabaseUrl.replace(/\/$/, '')}/auth/v1`
  const env = { url: supabaseUrl }
  if (jwks) env.jwks = jwks
  else if (jwksUrl) env.jwks = new URL(jwksUrl)

  return async function verifyAccessToken(expressRequest) {
    const authorization = expressRequest.get('authorization')
    const request = new Request('http://ledgerx.invalid/', {
      method: 'GET',
      headers: authorization ? { authorization } : {},
    })
    const result = await verify(request, {
      auth: 'user',
      audience: 'authenticated',
      issuer,
      env,
    })

    if (result.error) {
      if (result.error.status >= 500) {
        throw new HttpError(503, 'identity_provider_unavailable', 'Sign-in verification is temporarily unavailable.')
      }
      throw new HttpError(401, 'invalid_access_token', 'A valid sign-in token is required.')
    }

    const claims = result.data?.jwtClaims
    if (!claims || claims.role !== 'authenticated' || !uuidPattern.test(claims.sub ?? '')) {
      throw new HttpError(401, 'invalid_access_token', 'A valid sign-in token is required.')
    }
    return { subject: claims.sub }
  }
}
