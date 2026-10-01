---
title: How to record payroll payments
slug: how-to-record-payroll-payments
category: admin
audience: [entity_admin, owner]
summary: Export a payment list for the bank, then record each payment once the money has gone.
related: [how-to-run-payroll, how-to-set-pay-date-and-schedule-payslips, how-to-correct-payroll-after-approval]
route: /payroll
last_reviewed: 2026-10-01
status: published
---
Payments are recorded after payroll is approved. Recording a payment tells the app the person has been paid. Only record it when the money has really left.

## Steps
1. Open **Payroll** and choose the month.
2. Tick the approved people.
3. Tap **Export payment list**. This downloads a CSV of outstanding amounts for your bank.
   ![Bulk bar with payment actions](shot:payroll-pay-bulk)
4. Send the payments from your bank.
5. When the bank confirms, tick the people and tap **Record payment**.
6. In **Result**, choose **Paid (confirmed by bank)**.
7. Set **Date paid**. It cannot be in the future.
8. Choose the **Method**: Bank transfer, WPS agent / exchange, Exchange house, Cash or Cheque.
9. Add a **Reference** if you have one.
10. Tap **Preview**.
11. Tap **Record for** and the number of employees.
    ![Record payment form](shot:payroll-record-payment)

## What happens next
Each person's outstanding amount is paid in full unless you type an amount in **Amount**. The **Paid** box on the page goes up, and the page says how much is still to pay.

If a payment fails, choose **Failed / returned** and type **Why it failed**. It is kept for the record but does not count as paid.

Exporting never marks anyone paid. The file is not a WPS SIF file. Anything in **Payment lists exported** shows older exports. If a record is changed, an old export that contains it is marked void.

Accountants and payroll admins can record payments. A record with a payment cannot go back to draft. Use a correction instead.

## Common problems
- **I cannot choose today's date in the future.** Record the payment on the day the bank sends it.
- **Record payment is missing.** The person is not approved yet, or you have no payment permission.
- **I marked the wrong person.** Ask the Owner or a payroll admin how to correct it. We could not confirm a "undo payment" button.

## Related guides
- [How to run payroll for a month](/help/how-to-run-payroll)
- [How to set the pay date and schedule payslips](/help/how-to-set-pay-date-and-schedule-payslips)
- [How to correct payroll after approval](/help/how-to-correct-payroll-after-approval)
