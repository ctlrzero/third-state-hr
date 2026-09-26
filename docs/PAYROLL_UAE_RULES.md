# Payroll v2 — UAE rules used (checked 26 Sep 2026)

Sources: Federal Decree-Law 33/2021 as amended + Cabinet Resolution 1/2022
(MOHRE consolidated text), Ministerial Resolution 340/2026 (WPS, in force
1 Jun 2026). Confirm anything disputed against the official Arabic text.

## Enforced as legal requirements

| Rule | How payroll v2 applies it | Source |
|---|---|---|
| Overtime at least basic hourly + 25% | Settings refuse a multiplier below 1.25 | Art. 19(2) |
| Night overtime (10pm–4am) at least + 50%, shift workers excluded | Minimum 1.50; enter night hours separately | Art. 19(3) |
| Rest day / public holiday work: day off in lieu or + 50% | Minimum 1.50 | Arts. 19(4), 28 |
| Total deductions max 50% of wage | Warning on the record; settings refuse > 50% | Art. 25(2) |
| Damage max 5 days’ wage a month; fines max 5% | Shown on the deduction choices | Art. 25(1) |
| Advances: written consent, no interest | Stated on the advance form | Art. 25(1)(a) |
| Sick leave: 15 days full, 30 half, rest unpaid; none paid in probation | Leave type “tiered”; service-year counting; probation days unpaid | Art. 31 |
| Gratuity: 21 days basic per year (first 5), 30 after; pro-rated; ≥ 1 year; cap 2 years’ wage; unpaid leave excluded; not UAE nationals | Gratuity estimate on the employee drawer | Arts. 51, 33 |
| Final settlement within 14 days | Stated on the leaving section | Art. 53 |
| Wages due on the 1st of the following month (WPS) | Default pay day 1 | MR 340/2026 Art. 1 |

## Company choices (defaults, change in Payroll Settings)

| Choice | Default | Note |
|---|---|---|
| Day rate for proration and unpaid leave | Calendar days in the month | Art. 67 counts a month as 30 days; “fixed 30” is available |
| Unpaid-leave day includes | Basic + allowances | Law gives no formula |
| Overtime hourly rate for monthly staff | Basic ÷ 240 (30 × 8) | Basic, not total wage (Art. 19) |
| Approval | Two people | Owner single-step only when the owner switches it on |
| Tips | Branch pools, 4 methods | Labour law is silent on tips |
| Leave types unpaid | “Unpaid / Discretionary”, Hajj, Study | Edit per leave type if your policy differs |

## Not configured (needs information)

- **WPS SIF file**: the format (EDR/SCR records) is distributed by banks and
  exchange agents. It needs the employer MOHRE/WPS ID, agent routing code and
  each employee’s IBAN. The payment list export is a plain CSV, not a SIF.
- **Pension (GPSSA / ADPF) for UAE and GCC nationals**: not calculated. Rates
  and salary base must be confirmed before adding.
- **Annual leave pay and encashment**: leave is paid at full wage; encashment
  on leaving uses basic. Add encashment as a “Leave encashment” earning.
