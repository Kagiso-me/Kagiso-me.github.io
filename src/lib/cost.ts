// Single source of truth for homelab running cost (ZAR).
// Consumed by both /cost and the live spine so the two can never drift.

export const ONGOING = [
  { item: 'Backblaze B2 (offsite backup)', cost: 85 },
  { item: 'Domain — kagiso.me', cost: 15 },
  { item: 'Cloudflare (free tier)', cost: 0 },
  { item: 'GitHub Actions (free tier)', cost: 0 },
] as const;

export const ONGOING_TOTAL = ONGOING.reduce((s, o) => s + o.cost, 0);

// Always-on draw ≈ 127W continuous × 24h × 30d ≈ 91 kWh/month.
export const ELECTRICITY_KWH = 91;
export const ELECTRICITY_RATE = 3.5; // R/kWh — Johannesburg municipal tariff
export const ELECTRICITY_COST = Math.round(ELECTRICITY_KWH * ELECTRICITY_RATE);

// Actual cash outgoings — hardware excluded (already owned, no payments).
export const MONTHLY_TOTAL = ONGOING_TOTAL + ELECTRICITY_COST;

export const MONTHLY_LABEL = `R${MONTHLY_TOTAL}/mo`;
