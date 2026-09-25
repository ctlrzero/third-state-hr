import { useEffect, useState } from 'react'
import { Modal } from './ui'
import { registerConfirmHost, type ConfirmRequest } from '../lib/confirm'

const DESTRUCTIVE = /\b(cancel|deactivate|archive|discard|remove|delete|revoke)\b/i

export function ConfirmHost() {
  const [req, setReq] = useState<ConfirmRequest | null>(null)

  useEffect(() => {
    registerConfirmHost(setReq)
    return () => registerConfirmHost(null)
  }, [])

  function close(ok: boolean) {
    req?.resolve(ok)
    setReq(null)
  }

  const destructive = req ? DESTRUCTIVE.test(req.message) : false

  return (
    <Modal
      open={Boolean(req)}
      title="Please confirm"
      onClose={() => close(false)}
      footer={
        <>
          <button className="btn-secondary" onClick={() => close(false)}>
            Go back
          </button>
          <button className={destructive ? 'btn-danger' : 'btn-primary'} onClick={() => close(true)} data-autofocus>
            Confirm
          </button>
        </>
      }
    >
      <p>{req?.message}</p>
    </Modal>
  )
}
