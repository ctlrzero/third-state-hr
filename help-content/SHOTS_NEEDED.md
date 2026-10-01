# Screenshots needed

| shot key | article slug | sign in as | route | screen state to capture | annotation labels |
|---|---|---|---|---|---|
| set-password-form | quick-start-for-new-staff | any new invited user (open invite link) | /set-password | Set your password form, both fields filled with dots | 1 New password; 2 Confirm password; 3 Save password |
| staff-home | quick-start-for-new-staff | staff | / | Staff Home with "Your manager needs something" card, Next shifts, Leave balance | 1 Manager request button; 2 Next shifts; 3 Leave balance; 4 Menu / bottom bar |
| sign-in-form | how-to-sign-in-and-reset-your-password | signed out | /sign-in | Sign in form with email and password filled | 1 Work email; 2 Password / Show; 3 Sign in |
| sign-in-forgot-link | how-to-sign-in-and-reset-your-password | signed out | /sign-in | Forgot password screen (after tapping the link), email filled | 1 Forgot password? link (on sign-in page); 2 Work email on reset screen |
| my-profile-contact | update-your-profile-and-contact-details | staff | /me | Contact details card with Request change buttons | 1 Profile menu; 2 Contact details; 3 Request change |
| my-profile-request-change | update-your-profile-and-contact-details | staff | /me | Request a change modal open | 1 New value; 2 Reason; 3 Submit request |
| my-profile-missing-details | update-your-profile-and-contact-details | staff with an open profile request | /me#missing-details | Please fill in your missing details form | 1 Fields; 2 Save my details |
| my-profile-bank-details | update-your-profile-and-contact-details | staff with an open bank request | /me#payment-details | Your bank / payment details form | 1 How do you want to be paid?; 2 IBAN; 3 Send bank details |
| clock-before | how-to-clock-in-and-out | staff with a shift today, not clocked in | /clock | Clock in / out screen with Today's shift and blue Clock in button | 1 Clock menu; 2 Today's shift; 3 Clock in |
| clock-in-progress | how-to-clock-in-and-out | staff, clocked in | /clock | Red Clock out button, Clocked in time shown | 1 Clocked in time; 2 Clock out |
| clock-history | how-to-clock-in-and-out | staff with history | /clock | My last 30 days list incl. one Corrected row | 1 Planned/Actual; 2 Status badge; 3 Corrected note |
| my-schedule-upcoming | how-to-view-your-schedule-and-shifts | staff with shifts | /schedules | My schedule: Open Clock card, Upcoming shifts, Open shifts | 1 Schedule menu; 2 Upcoming shifts row; 3 Open shifts; 4 Take this shift |
| my-schedule-cant-come-in | how-to-view-your-schedule-and-shifts | staff with a future shift | /schedules | Can't come in form open under a shift | 1 Can’t come in; 2 Reason; 3 Tell my manager |
| cover-ask | how-to-ask-for-cover-or-take-a-colleagues-shift | staff, shift handovers on | /schedules | Ask for cover note field open | 1 Ask for cover; 2 Note field; 3 Send request |
| cover-colleagues | how-to-ask-for-cover-or-take-a-colleagues-shift | staff, colleague has an open cover request | /schedules | Colleagues need cover list | 1 Shift row; 2 I’ll cover it |
| cover-offers | how-to-ask-for-cover-or-take-a-colleagues-shift | staff with a manager offer | /schedules | Can you cover? box with Decline / Accept shift | 1 Offer details; 2 Decline; 3 Accept shift |
| leave-my-leave | how-to-request-leave | staff | /leave | My leave page with Balances, Request leave button, Your requests (one Pending) | 1 Leave menu; 2 Balances; 3 Request leave; 4 Your requests |
| leave-request-form | how-to-request-leave | staff | /leave | Request leave modal, type and dates filled, balance line visible | 1 Leave type; 2 Start date; 3 End date; 4 Balance line; 5 Submit request |
| notifications-bell | how-to-use-notifications | staff with unread | any page | Bell dropdown open | 1 Bell; 2 A notification; 3 Mark all read |
| notifications-page | how-to-use-notifications | staff | /notifications | Notifications page with Show unread only | 1 Show unread only; 2 Mark all as read; 3 Load older |
| docs-home-request | how-to-upload-or-renew-a-document | staff with an open document request | / | Home card Your manager needs something with Upload document button | 1 Request card; 2 Upload document |
| docs-upload-form | how-to-upload-or-renew-a-document | staff | /documents?upload=passport | Upload document modal, file chosen | 1 Document type; 2 Expiry date; 3 File; 4 Upload |
| docs-my-documents | how-to-upload-or-renew-a-document | staff with an expiring document | /documents | My documents with Expiring badge and Upload new copy button | 1 Documents menu; 2 Expiring badge; 3 Upload new copy |
| payslips-list | how-to-view-and-download-payslips | staff with a published payslip | /payroll | My payslips list | 1 Payslips menu; 2 A month row; 3 Net pay |
| payslips-detail | how-to-view-and-download-payslips | staff | /payroll | Payslip drawer open | 1 Earnings; 2 Deductions; 3 Net pay; 4 Download; 5 Open to print |
| people-list | how-to-view-and-manage-your-team | location_manager | /employees | People list with search and filters | 1 People menu; 2 Search; 3 Filter by status; 4 Filter by branch; 5 A name |
| people-employee-tabs | how-to-view-and-manage-your-team | location_manager | /employees/:id | Employee record with Edit details, tabs, Pending change requests | 1 Edit details; 2 Tabs; 3 Pending change requests; 4 Approve / Reject |
| ask-requests-card | how-to-ask-an-employee-for-missing-details | location_manager | /employees/:id | Requests to <name> card with both buttons | 1 Ask for missing details; 2 Ask for something |
| ask-missing-ticklist | how-to-ask-an-employee-for-missing-details | location_manager | /employees/:id | Ask <name> for… modal with groups, one Already asked item | 1 Groups; 2 Select all; 3 Note; 4 Due date; 5 Ask for button |
| ask-many-ticklist | how-to-ask-an-employee-for-missing-details | location_manager | /employees | Ask everyone in your branch for… modal | 1 Ask for missing details on People; 2 Ticks; 3 Ask for button |
| schedules-week-board | how-to-build-and-share-a-weekly-schedule | location_manager | /schedules | Week board with a Not shared and a Shared shift, status key visible | 1 Branch; 2 Week arrows / This week; 3 New shift; 4 Not shared shift; 5 Share week with staff |
| schedules-new-shift | how-to-build-and-share-a-weekly-schedule | location_manager | /schedules | New shift modal filled | 1 Branch/Date; 2 Start/End; 3 Assign to; 4 Create shift |
| schedules-share-week | how-to-build-and-share-a-weekly-schedule | location_manager, one branch chosen, drafts exist | /schedules | Share week with staff (n) button and confirmation | 1 Share week with staff (n); 2 Confirm |
| schedules-shift-actions | how-to-change-or-cancel-a-shared-shift | location_manager | /schedules | Shift actions panel for a shared shift | 1 Status note; 2 Edit (with a reason); 3 Reassign / find cover; 4 Change history; 5 Cancel shift |
| schedules-change-shift | how-to-change-or-cancel-a-shared-shift | location_manager | /schedules | Change shift (shared with staff) form with Reason | 1 Fields; 2 Reason for change; 3 Save changes |
| cover-find-sheet | how-to-find-cover-and-handle-swap-requests | location_manager | /schedules | Find cover panel, Pick someone tab, candidate selected | 1 Pick someone / Ask a few people tabs; 2 Candidate; 3 Assign |
| cover-offer-panel | how-to-find-cover-and-handle-swap-requests | location_manager | /schedules | Ask a few people tab with two ticked | 1 People ticks; 2 Message; 3 Send offer |
| cover-swap-requests | how-to-find-cover-and-handle-swap-requests | location_manager, a claimed swap exists | /schedules | Swap requests awaiting your decision card | 1 Swap row; 2 Reject; 3 Approve |
| schedules-repeating-form | how-to-set-up-repeating-shifts-and-auto-schedule | location_manager | /schedules?tab=setup | New recurring template modal | 1 Branch/Employee; 2 Day of week; 3 Start/End; 4 Effective from |
| auto-schedule-preview | how-to-set-up-repeating-shifts-and-auto-schedule | entity_admin | /schedules?tab=auto | Auto-schedule with period chosen, branches ticked, plan previewed | 1 Period; 2 Branches; 3 Preview plan; 4 Create button |
| today-board | how-to-use-the-today-board | location_manager | /today | Today board with counts, Needs you now with Find cover, Waiting for your approval | 1 Branch; 2 Counts; 3 Find cover; 4 Fix/Review; 5 Waiting for your approval |
| attendance-exceptions | how-to-review-attendance | location_manager | /attendance?tab=exceptions | Exceptions tab with a suggested clock-out row and a Correct row | 1 Branch/From/To; 2 Exceptions tab; 3 Confirm / Change… / Dismiss; 4 Correct |
| attendance-correct-form | how-to-review-attendance | location_manager | /attendance | Correct attendance panel with reason filled | 1 New clock-in; 2 New clock-out; 3 Reason; 4 Review changes |
| leave-awaiting-decision | how-to-approve-or-decline-leave | location_manager | /leave | Awaiting your decision card with a pending request | 1 Request details; 2 Reject; 3 Approve; 4 Recent decisions |
| leave-balances-adjust | how-to-manage-leave-balances | entity_admin | /employees/:id?tab=leave | Leave tab with Balances and Adjust links | 1 Leave tab; 2 Balances; 3 Adjust |
| leave-accrual-policies | how-to-manage-leave-balances | owner | /leave | Leave accrual policies card with one policy | 1 Configure policy; 2 Approve; 3 Period to run; 4 Run accrual |
| docs-register | how-to-review-and-approve-employee-documents | location_manager | /documents | Document register with Review status = Pending review and a Review button | 1 Document register tab; 2 Review status / Document type filters; 3 Review |
| docs-review-drawer | how-to-review-and-approve-employee-documents | location_manager | /documents | Review panel for a pending document | 1 View file; 2 Version history; 3 Reject; 4 Approve |
| docs-checklist | how-to-collect-and-track-employee-documents | entity_admin | /documents | Employee checklist tab with an employee chosen | 1 Employee checklist tab; 2 Employee picker; 3 Status badges; 4 Upload on behalf / Waive |
| onboarding-my-steps | how-to-complete-your-joining-steps | staff in pre-activation onboarding | /onboarding | Welcome page with Your joining steps progress and steps 1-5 | 1 Progress bar; 2 Your details; 3 Documents; 4 Salary payment; 5 Contract |
| onboarding-availability | how-to-complete-your-joining-steps | staff in onboarding | /onboarding | When you can work card with days ticked | 1 Day ticks; 2 Times; 3 Confirm availability |
| onboarding-dashboard | how-to-onboard-a-new-employee | entity_admin | /onboarding | Onboarding dashboard with Start onboarding, KPI cards, New starters list | 1 Start onboarding; 2 KPI cards; 3 List tabs |
| onboarding-start-form | how-to-onboard-a-new-employee | entity_admin | /onboarding | Start onboarding modal, Direct hire selected | 1 Direct hire; 2 Name/Email; 3 Branch/Job/Start date; 4 Start onboarding |
| onboarding-workspace | how-to-onboard-a-new-employee | entity_admin | /onboarding | Case workspace with Portal access, review, buttons | 1 Invite to portal; 2 Waiting for your review; 3 Starting pay; 4 Approve and activate |
| work-pattern-card | how-to-set-work-pattern-and-availability | entity_admin | /employees/:id?tab=schedule | Schedule tab with Work pattern card and Availability grid | 1 Schedule tab; 2 Work pattern; 3 Set pattern / Edit; 4 Availability |
| work-pattern-editor | how-to-set-work-pattern-and-availability | entity_admin | /employees/:id?tab=schedule | Work pattern editor open | 1 Working days per week; 2 Days off; 3 Shift type; 4 Save pattern |
| schedules-setup-tab | how-to-set-opening-hours-and-staffing-needs | entity_admin | /schedules?tab=setup | Setup tab with Branch setup, Staff self-service, Deleted shifts | 1 Setup tab; 2 Branch setup; 3 Staff self-service tick box |
| branch-setup-sheet | how-to-set-opening-hours-and-staffing-needs | entity_admin | /schedules?tab=setup | Branch setup panel with opening hours and a staffing need | 1 Branch tabs; 2 Opening hours; 3 + Add staffing need; 4 Save |
| payroll-month-prepare | how-to-run-payroll | entity_admin | /payroll | Payroll page top: month picker, Start another month, Prepare payroll, readiness checklist | 1 Payroll menu; 2 Payroll month; 3 Start another month; 4 Prepare payroll; 5 Readiness checklist |
| payroll-record-drawer | how-to-run-payroll | entity_admin | /payroll | One employee's record open | 1 Net pay; 2 Hours this month; 3 Earnings / Deductions; 4 Recalculate; 5 Approve |
| payroll-bulk-bar | how-to-run-payroll | entity_admin | /payroll | Table with people ticked and the bulk bar showing the main action | 1 Select all; 2 Status column; 3 Bulk bar main button |
| payroll-pay-bulk | how-to-record-payroll-payments | entity_admin | /payroll | Approved people ticked, bulk bar with Export payment list and Record payment | 1 Tick people; 2 Export payment list; 3 Record payment |
| payroll-record-payment | how-to-record-payroll-payments | entity_admin | /payroll | Record payment dialog | 1 Result; 2 Date paid; 3 Method; 4 Reference; 5 Preview; 6 Record for n employees |
| payroll-pay-date-panel | how-to-set-pay-date-and-schedule-payslips | entity_admin | /payroll | Pay date and payslips panel (not editing) | 1 Pay date; 2 Payslips plan; 3 Change dates |
| payroll-change-dates | how-to-set-pay-date-and-schedule-payslips | entity_admin | /payroll | Change dates form open | 1 Pay date; 2 Publish payslips on; 3 Only publish ... tick; 4 Save dates |
| payroll-return-draft | how-to-correct-payroll-after-approval | entity_admin | /payroll | Reason dialog for Return to draft | 1 Return to draft; 2 Reason; 3 Confirm |
| payroll-offcycle-button | how-to-run-an-off-cycle-or-final-settlement-payroll | entity_admin | /payroll | Month picker row with Off-cycle / final settlement button | 1 Off-cycle / final settlement |
| payroll-offcycle-form | how-to-run-an-off-cycle-or-final-settlement-payroll | entity_admin | /payroll | Off-cycle payroll modal filled | 1 Label; 2 Pay date; 3 Salary month; 4 Create |
| payroll-reports-drawer | how-to-use-payroll-reports-and-earlier-runs | entity_admin | /payroll | Payroll reports panel with report picker | 1 Report picker; 2 Table; 3 Download |
| payroll-earlier-runs | how-to-use-payroll-reports-and-earlier-runs | entity_admin (company with legacy runs) | /payroll | Earlier payroll runs section expanded | 1 Section title; 2 A run; 3 A payslip |
| payroll-tips-drawer | how-to-add-tips-advances-and-extra-pay | entity_admin | /payroll | Distribute tips panel with preview | 1 Branch and period; 2 Split method; 3 Preview; 4 Confirm distribution |
| payroll-advances-drawer | how-to-add-tips-advances-and-extra-pay | entity_admin | /payroll | Salary advances panel, New advance filled | 1 Employee; 2 Amount; 3 Instalments; 4 Save advance |
| payroll-hours-sheet | how-to-enter-hours-and-tips-for-payroll | location_manager | /payroll | Payroll inputs page with rows | 1 Month; 2 Load from attendance; 3 Row Save and confirm; 4 Confirm all pending |
| offboarding-list | how-to-offboard-an-employee | entity_admin | /offboarding | Offboarding page, Leaving tab, Start offboarding button | 1 Offboarding menu; 2 Start offboarding; 3 Tabs Leaving / Left / Cancelled |
| offboarding-start-form | how-to-offboard-an-employee | entity_admin | /offboarding | Start offboarding modal filled | 1 Employee; 2 Type; 3 Notice given on / Last working day; 4 Reason; 5 Start offboarding |
| offboarding-case | how-to-offboard-an-employee | entity_admin | /offboarding?open=<case> | Case panel with Checklist and Final settlement | 1 Checklist Done; 2 Start settlement in Payroll; 3 Finish offboarding |
| reports-metrics | how-to-use-reports-and-the-audit-log | entity_admin | /reports | Reports & audit with metric cards | 1 Reports menu; 2 Metric cards |
| reports-audit-log | how-to-use-reports-and-the-audit-log | entity_admin | /reports | Audit log filters and rows | 1 Module; 2 Record type; 3 From / To; 4 Export CSV |
| admin-users-tab | how-to-give-someone-access-and-send-an-invite | entity_admin | /admin?tab=users | Users & access list with Grant access and Send invite | 1 Users & access tab; 2 Grant access; 3 Send invite / Resend invite; 4 Revoke access |
| admin-grant-access | how-to-give-someone-access-and-send-an-invite | entity_admin | /admin?tab=users | Grant access modal filled | 1 Email; 2 Role; 3 Linked employee; 4 Grant access |
| manager-home | how-to-use-the-home-action-centre | location_manager | / | Manager Home with KPI cards, Action centre list, Operational coverage | 1 Home menu; 2 KPI cards; 3 Action centre row + Open; 4 Operational coverage |
