# Unverified or missing workflows (for the owner)

- **Install on phone (PWA / Add to Home Screen):** searched index.html, public/ and src for a web manifest, service worker or install prompt. None found. The Quick start says only that the website can be opened in a phone browser. Confirm whether you want an install guide.
- **Sign-in page title wording:** the sign-in heading says "Third State Café HR" while the app shell says "Third State HR". Guides use "Third State HR". Confirm the product name.
- **Change password while signed in:** no menu item for it found. Guides only describe Forgot password.
- **Shift Supervisor "view and manage my team (People)":** supervisors have no People, Leave approval, Documents review or Schedules board in the code (route guards in src/lib/nav.ts; role hint in Admin > Users & access). They use the staff pages plus **Today** and **Attendance** (exceptions and clock corrections only, never pay time). The manager guides list shift_supervisor only on the Today and Attendance guides. Confirm this is the intended scope.
- **Shift Supervisor and swaps from Today:** the Today board shows **Approve/Reject** for swaps to everyone who sees it. Whether the server accepts a supervisor's approval was not checked. The swap guide lists only Branch Manager and above.
- **Who applies "Hours changes" in Attendance:** the Apply/Reject buttons are shown without a role check in the page. A migration comment says owner/entity admin approval is required. The attendance guide says "Approvers tap Apply or Reject" without naming roles. Confirm.
- **Staff-changeable availability after onboarding:** the only staff screen is the "When you can work" step inside onboarding (only if the checklist template has an availability task). The employee Work pattern card shows availability read-only. The guide says so. Confirm whether staff or managers need a screen to change availability later.
- **Install on phone:** see above (no manifest or install prompt found).
- **Undo a recorded payroll payment:** not found. The payments guide tells admins to ask the Owner or a payroll admin. Confirm the real process.
- **Earlier payroll runs label:** the app text is "Earlier payroll runs (history — payroll is now run on this screen)", not "(read-only)". The guide quotes "Earlier payroll runs" and explains read-only in prose.
- **Menu name "Payslips":** the staff menu item is **Payslips**; the page title is **My payslips**. Both are used correctly in the guides.
- **Approval mode wording in payroll guide:** the number of people needed depends on the Settings > Approval option (Two people / Prepare → review → approve / Owner single step). The guide describes the standard two-person setting and mentions the others. Confirm the company's actual setting.
- **Sensitive-document approval by Company Admin:** documents guide follows canRoleApprove in src/lib/documents.ts (Owner approves a Company Admin's own sensitive upload). The database trigger is authoritative and was not re-read.
- **Employee transfer:** People record has a **Transfer** button (admins). No guide was written; behaviour not documented.
- **Recruiting and My Interviews:** present in the menu but outside the requested scope. No guides written.
- **Admin tabs not covered:** Entities & branches, Policies and Bulk import (Admin page) have no guide.
- **Labels inferred:** none intentionally. Where a button label was not visible in code, the guide describes the action in words (for example "Save the policy", "confirm in the box", "Tap the confirm button" for Reason dialogs where the label is Confirm).
