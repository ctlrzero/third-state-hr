# Screenshot capture notes

All 81 keys in `../SHOTS_NEEDED.md` have a PNG, plus one extra (`sign-in-reset-screen`). Every shot was taken from a mock
environment with synthetic people only (Sara Khan, Omar Ali, Noor Rahman, Maria Santos, Layla Hassan, "Demo Hospitality LLC",
branches "Marina Café" and "Airport Kiosk"). No production data was used. The IBAN in `my-profile-bank-details` is a dummy value.

## Where a numbered label is not drawn
These labels from SHOTS_NEEDED.md are not on the image, because the control does not exist on that screen in the mock. The
manifest only lists the numbers that are drawn.

| key | label not drawn | why |
|---|---|---|
| sign-in-forgot-link | 2 Work email on reset screen | The email field is on the next screen. It is shown in the extra shot `sign-in-reset-screen` (marker 2). |
| notifications-page | 3 Load older | Only appears when a person has 50 or more notifications. Retake with a real account if the article needs it. |
| ask-many-ticklist | 1 Ask for missing details on People | That button sits on the page behind the modal. Marker 1 is on the People page itself (`people-list` shows the page). |
| today-board | 1 Branch | The Branch picker only shows for people who can see more than one branch (Company Admin, Owner). Branch Manager view has none. |

## Things to know
- Desktop shots use a 1024 px wide window (not 1280) so the sidebar and content stay readable at article width. Wide screens
  (week board, payroll, today board, reports) are 1280 px. Staff Home and My schedule (`staff-home`, `my-schedule-upcoming`)
  are phone width (390 px) so the bottom menu bar can be marked.
- Dates are relative to the capture day (1 Oct 2026). Shifts, expiry dates and "pay date" will look older as time passes.
- The capture browser shows time fields with AM/PM (for example 09:00 AM). On a real phone or PC they follow the device setting.
- AI helpers (cover suggestions, roster summary, payroll explainer) were offline in the mock. `cover-offer-panel` therefore shows
  "Suggestions aren't available right now". On the live app, suggestions appear when the AI key is set.
- `payroll-hours-sheet` shows draft records, so the per-person buttons are active.
- The employee record header shows a "Pay not set" badge in some shots because the mock has no pay history. Ignore it.
- `onboarding-workspace` is a tall panel (about 256 KB, just over the 250 KB target). Crop it if the article column needs it smaller.
- Browser tab titles, favicon and the sign-in heading show the app's own text ("Third State Café HR").

## How to retake
The mock harness is not stored in the repo. It lived in the session scratchpad: a Vite page that loads the real `src/App`
with `src/lib/supabase` and the auth context replaced by in-memory mocks, plus a Playwright script that draws the numbered markers
from the real element positions. To retake a shot against live screens, sign in with a test account, open the route in
SHOTS_NEEDED.md and add markers by hand in the same style (red-orange circle, white bold number, thin outline on the control).
