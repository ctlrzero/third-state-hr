// Promise-based replacement for window.confirm(). Native browser dialogs block
// the page, ignore the design system and are not accessible; <ConfirmHost />
// (mounted once in App) renders the shared <Modal> instead.
//
//   if (!(await confirmDialog('Publish all draft shifts?'))) return

export type ConfirmRequest = { message: string; resolve: (ok: boolean) => void }

let show: ((r: ConfirmRequest) => void) | null = null

export function registerConfirmHost(fn: ((r: ConfirmRequest) => void) | null) {
  show = fn
}

export function confirmDialog(message: string): Promise<boolean> {
  return new Promise((resolve) => {
    // Host not mounted (e.g. in a unit test): fail safe and do nothing.
    if (!show) return resolve(false)
    show({ message, resolve })
  })
}
