# RCA — <incident / drill title>

> Root-cause analysis. Blameless: focus on systems and signals, not individuals. Fill every section; use `<fill>` for anything still unknown.

- **Incident / drill:** `<e.g. Drill 01 — Elevated 5xx>`
- **Date (UTC):** `<fill>`
- **Author:** `<fill>`
- **Status:** `<Draft | In review | Final>`
- **Severity:** `<SEV1 / SEV2 / SEV3 — or "drill">`
- **Detected by:** `<alarm name / manual / SNS cops-alerts>`

## 1. Summary

`<2–4 sentences: what happened, what the impact was, how it was resolved. Written so someone with no context understands it.>`

## 2. Timeline (UTC)

| Time | Event |
|------|-------|
| `<fill>` | Injection / trigger occurred |
| `<fill>` | First alarm entered ALARM (`<alarm name>`) |
| `<fill>` | Composite `cops-service-health` → ALARM |
| `<fill>` | SNS `cops-alerts` notification delivered |
| `<fill>` | Investigation / diagnosis |
| `<fill>` | Mitigation applied |
| `<fill>` | Service confirmed recovered / alarms cleared |

## 3. Impact

- **User-facing impact:** `<errors, latency, availability — quantify if possible>`
- **Duration:** `<inject → full recovery>`
- **Scope:** `<which components: ALB / ASG / RDS / app>`
- **Data impact:** `<none / describe>`

## 4. Root cause

`<The single primary cause. Use "5 whys" if helpful — trace from the symptom down to the underlying condition.>`

## 5. Contributing factors

- `<Conditions that made it worse / harder to detect / slower to fix — e.g. thresholds, missing retries, no runbook, alarm lag.>`

## 6. Detection & response assessment

- **Time to detect (TTD):** `<inject → first alarm>`
- **Time to mitigate (TTM):** `<inject → recovery>`
- **Did the expected alarm(s) fire?** `<yes/no — vs. the drill hypothesis>`
- **Was the alert actionable?** `<did it point at the right component?>`

## 7. What went well

- `<Things that worked: fast detection, clean auto-heal, good runbook, useful dashboard.>`

## 8. What didn't / where we got lucky

- `<Gaps, near-misses, manual toil, noisy or missing alarms.>`

## 9. Corrective actions

| # | Action | Type (prevent / detect / mitigate) | Owner | Due | Status |
|---|--------|-----------------------------------|-------|-----|--------|
| 1 | `<fill>` | `<fill>` | `<fill>` | `<fill>` | `<Open / Done>` |
| 2 | `<fill>` | `<fill>` | `<fill>` | `<fill>` | `<Open / Done>` |
| 3 | `<fill>` | `<fill>` | `<fill>` | `<fill>` | `<Open / Done>` |

## 10. Links / evidence

- Drill plan: `<incidents/NN-*.md>`
- Dashboard / screenshots: `<fill>`
- Relevant logs (Logs Insights query): `<fill>`
