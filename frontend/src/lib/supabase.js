import { createClient } from '@supabase/supabase-js'

const projectUrl = import.meta.env.VITE_SUPABASE_URL?.trim() ?? ''
const publishableKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY?.trim() ?? ''

function validateConfiguration() {
  if (!projectUrl || !publishableKey) {
    return 'Authentication is not configured. Add the Supabase project URL and publishable key to frontend/.env.local.'
  }

  try {
    const parsed = new URL(projectUrl)
    if (parsed.protocol !== 'https:' && parsed.hostname !== 'localhost' && parsed.hostname !== '127.0.0.1') {
      return 'The Supabase project URL must use HTTPS.'
    }
  } catch {
    return 'The Supabase project URL is not valid.'
  }

  return null
}

export const supabaseConfigurationError = validateConfiguration()
export const supabase = supabaseConfigurationError ? null : createClient(projectUrl, publishableKey, {
  auth: {
    flowType: 'pkce',
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
})
