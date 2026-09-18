# Jay presentation website

Self-contained Czech product website. Open `index.html` directly in a browser or serve this directory with any static HTTP server. No build, dependencies, third-party fonts, tracking, cookies, or form backend are required. No publication or infrastructure changes were made.

## Files

- `index.html`: product, team/NIS2 direction, privacy, Free/Team/Enterprise pricing, planned user-owned storage and beta access.
- `business-case.html`: standalone partner/investor presentation, naming, competitive sources, revised business-only revenue model and roadmap. No links to this page exist on index.html; noindex/nofollow is set (not access control).
- `styles.css`, `app.js`: responsive layout, accessible audience tabs, billing toggle and mobile navigation.
- `assets/jay-mark.svg`: original vector bird / speech bubble mark, also used as favicon.
- `verify.mjs`: static structural checks, run with 
ode www/verify.mjs` from the repository root.

## Content decisions

Use Jay by ZCloud for the proposed brand. The existing application still uses CallType and CT handles; renaming application binaries, infrastructure and code is outside this presentation-site change. The chat is explicitly a visual concept, not a screenshot or working messenger.

Current product claims are grounded in README and the beta-status / Azure beta plan from 14 September 2026. Paid plans and organization administration are proposals, not available services. The external beta CTA points to the already documented Azure Static Web Apps URL. Business contact goes to the user's existing ZCloud website; no unverified mailbox or nonfunctional lead form was invented.

Competitor pricing checked 16 September 2026. Sources are linked in both HTML pages. Cost ranges, currency conversions, DPH treatment and conversion rates are explicitly planning assumptions. The beta Azure estimate excludes full existing-server and staffing costs. No traction, security audit, SLA or trademark availability is claimed.

## security.txt

`.well-known/security.txt` (RFC 9116) carries the owner's security contact
(set 2026-09-18, see `docs/security/incident-response.md`). Its `Expires`
line must stay in the future — renew it at least yearly. The API serves its own copy at
`GET /.well-known/security.txt`, driven by config key `Security:ContactUri`
(404 while unset) — the two are independent files and must be updated
together.

## Before publication

Confirm brand/domain clearance, billing terms and exact legal/operator details. Replace the general ZCloud contact destination with an approved direct business contact if desired. Set the canonical URL and social preview image once the actual public hostname is chosen. No hostname is fabricated in metadata. Recheck pricing and beta status before publishing. The website itself does not collect data; the linked beta is a separate application.

## Design

Petrol `#003840`, white, orange `#FF8545`, mint `#E9F3F0`. Local system typography (Aptos / Segoe UI), oversized left-aligned hero, original bird mark, lightweight illustrated chat, quiet feature sections. Responsive menu at 850px, single-column layout at 620px. Keyboard-operated tabs follow WAI-ARIA arrow/Home/End conventions; native details handle FAQ disclosure. Reduced-motion preferences are respected.

## Verification performed

- 
ode www/verify.mjs`: Local links/resources, unique IDs, ARIA references, Czech metadata and beta disclosures passed.
- 
ode --check www/app.js`: passed.
- Browser: audience selection and arrow-key navigation, Team monthly price 119 and annual-equivalent price 99, minimum-seat totals, mobile navigation close-on-link, and FAQ expansion passed.
- No console warnings/errors during the tested interactions. Document width checked at 320, 390 and 768 pixel viewport overrides and the default desktop viewport; no horizontal document overflow. Business-case page checked at mobile/tablet size as well.
- Visually inspected desktop hero, pricing, mobile hero/pricing and the business-case page. Fixed overlapping chat-concept caption; rechecked its separation from the illustration.

## Product revision — 16 September 2026

Personal use is free; there is no Jay Plus. Revenue proposals focus on Team and Enterprise. NIS2 is a development direction supporting customer security measures, not a verified compliance claim. Team is the default audience tab. Planned backup destinations are user-owned Google Drive, OneDrive or zDrive, with no bundled backup quotas. Existing beta backups still use server-side Blob storage; no backend changes were made. Backup documentation evidence: docs/beta-status.md line 12 and docs/superpowers/plans/2026-09-16-beta-zadani.md task D02.
Backup policy clarified: optional application setting independent of every Jay plan. No backup feature appears in pricing cards; storage capacity and provider fees (including zDrive) are separate. Revised browser checks confirmed Free/Team/Enterprise cards, no homepage investor links, no backups in pricing and Team monthly/yearly toggles.

Latest offer: Jay zdarma includes personal and group chat, also for small teams; Jay Business CTA is Domluvit firemni pilot; individual deployment is custom. Public seat prices and billing toggle removed. Pricing comparison replaced by group-chat vs organization-management explanation. 99 CZK retained only as an internal hypothesis on the unlinked investor page.
