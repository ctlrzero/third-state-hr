// Minimal, dependency-free PDF 1.4 writer: one or more A4 pages, the two
// standard Helvetica fonts, text, lines and filled rectangles. Enough for a
// payslip; keeps a ~300 kB PDF library out of the bundle. Output is a real,
// standards-conformant PDF (valid xref table), not a print-to-PDF fallback.

export const A4 = { width: 595.28, height: 841.89 }

type Rgb = [number, number, number]

// Helvetica advance widths (1/1000 em) for the characters we render most;
// anything else falls back to an average width. Used for right-alignment.
const HELVETICA_WIDTHS: Record<string, number> = {
  ' ': 278, '.': 278, ',': 278, '-': 333, ':': 278, '/': 278, '(': 333, ')': 333, '%': 889, '#': 556,
  '0': 556, '1': 556, '2': 556, '3': 556, '4': 556, '5': 556, '6': 556, '7': 556, '8': 556, '9': 556,
  A: 667, B: 667, C: 722, D: 722, E: 667, F: 611, G: 778, H: 722, I: 278, J: 500, K: 667, L: 556, M: 833,
  N: 722, O: 778, P: 667, Q: 778, R: 722, S: 667, T: 611, U: 722, V: 667, W: 944, X: 667, Y: 667, Z: 611,
  a: 556, b: 556, c: 500, d: 556, e: 556, f: 278, g: 556, h: 556, i: 222, j: 222, k: 500, l: 222, m: 833,
  n: 556, o: 556, p: 556, q: 556, r: 333, s: 500, t: 278, u: 556, v: 500, w: 722, x: 500, y: 500, z: 500,
}
const BOLD_FACTOR = 1.05

export function textWidth(text: string, size: number, bold = false): number {
  let w = 0
  for (const ch of text) w += HELVETICA_WIDTHS[ch] ?? 556
  return (w / 1000) * size * (bold ? BOLD_FACTOR : 1)
}

/** Encode a JS string as a PDF literal string in WinAnsi (Latin-1 subset). */
export function pdfString(text: string): string {
  const map: Record<string, string> = { '–': '-', '—': '-', '’': "'", '‘': "'", '“': '"', '”': '"', '…': '...' }
  let out = ''
  for (const raw of text) {
    const ch = map[raw] ?? raw
    for (const c of ch) {
      const code = c.charCodeAt(0)
      if (c === '\\' || c === '(' || c === ')') out += '\\' + c
      else if (code >= 32 && code <= 126) out += c
      else if (code >= 160 && code <= 255) out += '\\' + code.toString(8).padStart(3, '0')
      else out += '?'
    }
  }
  return `(${out})`
}

const n = (v: number) => (Math.round(v * 100) / 100).toString()

export class PdfDoc {
  private pages: string[][] = [[]]

  private get ops() {
    return this.pages[this.pages.length - 1]
  }

  addPage() {
    this.pages.push([])
  }

  /** y is measured from the TOP of the page, like screen coordinates. */
  text(x: number, y: number, str: string, opts: { size?: number; bold?: boolean; color?: Rgb; align?: 'left' | 'right' } = {}) {
    const size = opts.size ?? 10
    const [r, g, b] = opts.color ?? [0.09, 0.13, 0.2]
    const px = opts.align === 'right' ? x - textWidth(str, size, opts.bold) : x
    this.ops.push(
      `BT /${opts.bold ? 'F2' : 'F1'} ${n(size)} Tf ${n(r)} ${n(g)} ${n(b)} rg ${n(px)} ${n(A4.height - y)} Td ${pdfString(str)} Tj ET`
    )
  }

  line(x1: number, y1: number, x2: number, y2: number, color: Rgb = [0.86, 0.89, 0.93], width = 0.75) {
    this.ops.push(`${n(width)} w ${n(color[0])} ${n(color[1])} ${n(color[2])} RG ${n(x1)} ${n(A4.height - y1)} m ${n(x2)} ${n(A4.height - y2)} l S`)
  }

  rect(x: number, y: number, w: number, h: number, fill: Rgb) {
    this.ops.push(`${n(fill[0])} ${n(fill[1])} ${n(fill[2])} rg ${n(x)} ${n(A4.height - y - h)} ${n(w)} ${n(h)} re f`)
  }

  /** Serialise to PDF bytes. */
  toBytes(meta: { title?: string } = {}): Uint8Array {
    const objects: string[] = []
    const add = (body: string) => {
      objects.push(body)
      return objects.length
    }
    const catalogId = add('') // placeholder, filled below
    const pagesId = add('')
    const f1 = add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>')
    const f2 = add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>')
    const pageIds: number[] = []
    for (const ops of this.pages) {
      const content = ops.join('\n')
      const contentId = add(`<< /Length ${latin1Length(content)} >>\nstream\n${content}\nendstream`)
      pageIds.push(
        add(
          `<< /Type /Page /Parent ${pagesId} 0 R /MediaBox [0 0 ${n(A4.width)} ${n(A4.height)}] /Resources << /Font << /F1 ${f1} 0 R /F2 ${f2} 0 R >> >> /Contents ${contentId} 0 R >>`
        )
      )
    }
    objects[catalogId - 1] = `<< /Type /Catalog /Pages ${pagesId} 0 R >>`
    objects[pagesId - 1] = `<< /Type /Pages /Kids [${pageIds.map((id) => `${id} 0 R`).join(' ')}] /Count ${pageIds.length} >>`
    const infoId = add(`<< /Title ${pdfString(meta.title ?? 'Document')} /Producer (Third State HR) >>`)

    let out = '%PDF-1.4\n%âãÏÓ\n'
    const offsets: number[] = []
    objects.forEach((body, i) => {
      offsets.push(latin1Length(out))
      out += `${i + 1} 0 obj\n${body}\nendobj\n`
    })
    const xref = latin1Length(out)
    out += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`
    for (const off of offsets) out += `${String(off).padStart(10, '0')} 00000 n \n`
    out += `trailer\n<< /Size ${objects.length + 1} /Root ${catalogId} 0 R /Info ${infoId} 0 R >>\nstartxref\n${xref}\n%%EOF\n`

    const bytes = new Uint8Array(out.length)
    for (let i = 0; i < out.length; i++) bytes[i] = out.charCodeAt(i) & 0xff
    return bytes
  }
}

function latin1Length(s: string) {
  // All content is ASCII/Latin-1 after pdfString escaping, so 1 char = 1 byte.
  return s.length
}

export function downloadBytes(bytes: Uint8Array, filename: string, mime = 'application/pdf') {
  const blob = new Blob([bytes as BlobPart], { type: mime })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
