import type { OffboardingCase } from './api/offboarding'
import { SEPARATION_LABEL } from './offboarding'
import { fmtDate, todayDubai } from './format'

// Bilingual (EN/AR) resignation-acceptance or end-of-employment letter.
// Rendered as HTML and printed via the browser's own print-to-PDF, rather
// than through lib/pdf.ts's hand-rolled PDF writer — that writer only
// supports WinAnsi/Helvetica and cannot render Arabic glyphs or RTL layout,
// while the browser's native text/font stack handles both for free.

const AR_SEPARATION_LABEL: Record<string, string> = {
  resignation: 'استقالة',
  termination: 'إنهاء خدمة',
  dismissal_art44: 'فصل بدون إشعار (المادة 44)',
  end_of_contract: 'انتهاء العقد',
  mutual_agreement: 'اتفاق متبادل',
  probation_not_confirmed: 'عدم تثبيت بعد فترة التجربة',
  no_show: 'عدم الحضور',
  retirement: 'تقاعد',
  death: 'وفاة',
  other: 'أخرى',
}

function esc(s: string) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}
function nl2p(s: string) {
  return s
    .split('\n\n')
    .map((p) => `<p>${esc(p).replace(/\n/g, '<br/>')}</p>`)
    .join('')
}

export function buildOffboardingLetterHtml(d: OffboardingCase, companyName: string): string {
  const resign = d.case.separation_type === 'resignation'
  const today = fmtDate(todayDubai())
  const position = d.employee.position ?? 'your position'
  const lastDay = fmtDate(d.case.last_working_date)

  const enTitle = resign ? 'Acceptance of Resignation' : 'Notice of End of Employment'
  const arTitle = resign ? 'قبول الاستقالة' : 'إشعار بإنهاء الخدمة'

  const enBody = resign
    ? `Dear ${d.employee.name},\n\nWe acknowledge receipt of your resignation from the position of ${position} at ${companyName}. Your last working day will be ${lastDay}.\n\nWe thank you for your service and wish you well in your future endeavours. Your final settlement, including any outstanding wages, leave balance and end-of-service benefits, will be processed in accordance with UAE Federal Decree-Law No. 33 of 2021.`
    : `Dear ${d.employee.name},\n\nThis letter is to formally notify you that your employment with ${companyName} in the position of ${position} will end on ${lastDay} (${SEPARATION_LABEL[d.case.separation_type]}).\n\nYour final settlement, including any outstanding wages, leave balance and end-of-service benefits, will be processed in accordance with UAE Federal Decree-Law No. 33 of 2021.`

  const arBody = resign
    ? `عزيزي/عزيزتي ${d.employee.name}،\n\nنُقر باستلام استقالتكم من منصب ${position} لدى ${companyName}. سيكون آخر يوم عمل لكم بتاريخ ${lastDay}.\n\nنشكركم على خدمتكم ونتمنى لكم التوفيق في مساعيكم المستقبلية. ستتم تسوية مستحقاتكم النهائية، بما في ذلك أي أجور مستحقة ورصيد الإجازات ومكافأة نهاية الخدمة، وفقًا لأحكام المرسوم بقانون اتحادي رقم 33 لسنة 2021.`
    : `عزيزي/عزيزتي ${d.employee.name}،\n\nنحيطكم علمًا رسميًا بأن عملكم لدى ${companyName} في منصب ${position} سينتهي بتاريخ ${lastDay} (${AR_SEPARATION_LABEL[d.case.separation_type] ?? ''}).\n\nستتم تسوية مستحقاتكم النهائية، بما في ذلك أي أجور مستحقة ورصيد الإجازات ومكافأة نهاية الخدمة، وفقًا لأحكام المرسوم بقانون اتحادي رقم 33 لسنة 2021.`

  return `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<title>${esc(enTitle)} — ${esc(d.employee.name)}</title>
<style>
  body { font-family: Arial, Helvetica, sans-serif; color: #111; max-width: 720px; margin: 40px auto; line-height: 1.6; padding: 0 16px; }
  h1 { font-size: 18px; margin: 0 0 4px; }
  h2 { font-size: 15px; margin: 0 0 12px; }
  .meta { color: #555; font-size: 13px; margin-bottom: 24px; }
  .letter { margin-bottom: 32px; }
  .ar { direction: rtl; text-align: right; font-family: 'Segoe UI', Tahoma, Arial, sans-serif; }
  .sig { margin-top: 40px; }
  hr { border: none; border-top: 1px solid #ddd; margin: 32px 0; }
  @media print { body { margin: 0; } }
</style>
</head>
<body>
  <div class="letter">
    <h1>${esc(companyName)}</h1>
    <p class="meta">${esc(today)}</p>
    <h2>${esc(enTitle)}</h2>
    ${nl2p(enBody)}
    <div class="sig"><p>Sincerely,</p><p>${esc(companyName)} — Human Resources</p></div>
  </div>
  <hr />
  <div class="letter ar">
    <h1>${esc(companyName)}</h1>
    <p class="meta">${esc(today)}</p>
    <h2>${esc(arTitle)}</h2>
    ${nl2p(arBody)}
    <div class="sig"><p>وتفضلوا بقبول فائق الاحترام،</p><p>${esc(companyName)} — الموارد البشرية</p></div>
  </div>
</body>
</html>`
}

/** Opens the letter in a new tab and triggers the browser's print dialog (Save as PDF). */
export function openOffboardingLetterForPrint(d: OffboardingCase, companyName: string) {
  const html = buildOffboardingLetterHtml(d, companyName)
  const w = window.open('', '_blank', 'noopener')
  if (!w) return
  w.document.open()
  w.document.write(html)
  w.document.close()
  w.focus()
  setTimeout(() => w.print(), 300)
}
