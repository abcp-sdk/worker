// App-level reactive state: the bearer token, the connected worker's identity,
// the shell's virtual cwd, and the resolved theme. Kept in one place so the
// gate, shell, files and jobs surfaces share it.
import { createWorkerClient, type WorkerClient } from './worker'

const TOKEN_KEY = 'agent-worker.token'
const CWD_KEY = 'agent-worker.cwd'

export const session = $state({
  token: localStorage.getItem(TOKEN_KEY) ?? '',
  /** Absolute workspace root reported by Info ('' until known). */
  workspace: '',
  /** Absolute working directory of the shell (client-side only). */
  cwd: localStorage.getItem(CWD_KEY) ?? '',
  os: '',
  arch: '',
  bootId: '',
  connected: false,
})

export function setToken(tok: string) {
  session.token = tok
  if (tok) localStorage.setItem(TOKEN_KEY, tok)
  else localStorage.removeItem(TOKEN_KEY)
}

export function setCwd(c: string) {
  session.cwd = c
  localStorage.setItem(CWD_KEY, c)
}

export function client(): WorkerClient {
  return createWorkerClient(session.token)
}

// ---- path helpers (absolute, unconfined) ----

/** Collapse //, ., .. in an absolute path. `..` at "/" stays "/". */
export function normAbs(p: string): string {
  const parts: string[] = []
  for (const seg of String(p).split('/')) {
    if (seg === '' || seg === '.') continue
    if (seg === '..') {
      if (parts.length) parts.pop()
      continue
    }
    parts.push(seg)
  }
  return '/' + parts.join('/')
}

/** Resolve `target` (may be relative) against an absolute `base`. */
export function resolveAbs(
  base: string,
  target: string | null | undefined,
): string {
  const t = String(target ?? '').trim()
  if (t === '' || t === '~') return session.workspace || '/'
  if (t.startsWith('/')) return normAbs(t)
  return normAbs((base || '/') + '/' + t)
}

/** Make a FileList entry path absolute (it is workspace-relative inside the
 *  root, absolute outside). */
export function absOf(p: string): string {
  return String(p).startsWith('/')
    ? normAbs(p)
    : normAbs((session.workspace || '') + '/' + p)
}

export function basename(p: string): string {
  return String(p).replace(/\/+$/, '').split('/').pop() || p
}

export function fmtSize(n: number): string {
  n = Number(n) || 0
  if (n < 1024) return `${n} B`
  if (n < 1048576) return `${(n / 1024).toFixed(1)} KiB`
  return `${(n / 1048576).toFixed(1)} MiB`
}

/** Strip ANSI/VT escape sequences (CSI, OSC incl. hyperlinks, DCS, single). */
export function stripAnsi(s: string): string {
  return String(s)
    .replace(/\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)/g, '')
    .replace(/\u001bP[\s\S]*?\u001b\\/g, '')
    .replace(/\u001b[@-Z\\-_]/g, '')
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, '')
}
