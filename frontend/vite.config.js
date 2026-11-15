import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig(({ mode }) => {
  const frontendEnv = loadEnv(mode, process.cwd(), '')
  const apiTarget = process.env.API_PROXY_TARGET || frontendEnv.API_PROXY_TARGET || 'http://127.0.0.1:8080'
  const frontendPort = Number(process.env.FRONTEND_PORT || frontendEnv.FRONTEND_PORT || 5173)
  return {
    plugins: [react()],
    server: {
      host: '127.0.0.1',
      port: frontendPort,
      strictPort: false,
      proxy: { '/api': { target: apiTarget, changeOrigin: true } },
    },
    test: {
      environment: 'jsdom',
      setupFiles: './src/test/setup.js',
      css: true,
    },
  }
})
