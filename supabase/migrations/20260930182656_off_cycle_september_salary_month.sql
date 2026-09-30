-- The owner confirmed the two one-off runs paid on 1 Oct 2026 ("Jordan September salary" and "New Joiner")
-- are September 2026 salaries, so their payslips should say "September 2026" (not the run title).
-- Only the salary month is set; amounts, approvals and payments are untouched.
update public.payroll_periods
set for_month = '2026-09-01', pay_date = coalesce(pay_date, period_end)
where kind = 'off_cycle' and period_start = '2026-10-01' and for_month is null
  and label in ('Jordan September salary', 'New Joiner');
