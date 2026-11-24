import { execFileSync } from 'node:child_process'
import { isIP } from 'node:net'
import { type Request, type Response } from 'express'

const HOSTNAME_REGEX = /^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/

export function systemDiagnostics () {
  return (req: Request, res: Response) => {
    const host = String(req.query.host ?? '127.0.0.1')
    if (!isIP(host) && !HOSTNAME_REGEX.test(host)) {
      res.status(400).json({ status: 'error', message: 'Invalid host' })
      return
    }
    const output = execFileSync('ping', ['-c', '1', host]).toString()
    res.status(200).json({ status: 'ok', output })
  }
}
