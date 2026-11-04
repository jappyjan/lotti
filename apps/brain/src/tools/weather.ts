import { z } from 'zod';
import type { ToolDef } from './registry.ts';

const WMO: Record<number, string> = {
  0: 'clear',
  1: 'mostly clear',
  2: 'partly cloudy',
  3: 'overcast',
  45: 'fog',
  48: 'rime fog',
  51: 'light drizzle',
  53: 'drizzle',
  55: 'heavy drizzle',
  56: 'freezing drizzle',
  57: 'heavy freezing drizzle',
  61: 'light rain',
  63: 'rain',
  65: 'heavy rain',
  66: 'freezing rain',
  67: 'heavy freezing rain',
  71: 'light snow',
  73: 'snow',
  75: 'heavy snow',
  77: 'snow grains',
  80: 'light showers',
  81: 'showers',
  82: 'heavy showers',
  85: 'snow showers',
  86: 'heavy snow showers',
  95: 'thunderstorm',
  96: 'thunderstorm with hail',
  99: 'severe thunderstorm with hail',
};
const wmo = (c: number) => WMO[c] ?? `code ${c}`;

const HHMM = /^([01]?\d|2[0-3]):([0-5]\d)$/;
const pad = (n: number) => String(n).padStart(2, '0');
const ymd = (ms: number) => {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
};

export const NO_LOCATION =
  "No location given. Call the `location` tool first to get the phone's current position (then pass lat/lon), or pass a place name in `place`.";

const schema = z.object({
  place: z
    .string()
    .optional()
    .describe('Place name, e.g. "Hamburg" (geocoded). Use instead of lat/lon.'),
  lat: z
    .number()
    .min(-90)
    .max(90)
    .optional()
    .describe('Latitude, e.g. from the `location` tool'),
  lon: z.number().min(-180).max(180).optional().describe('Longitude'),
  date: z
    .string()
    .regex(/^\d{4}-\d{2}-\d{2}$/)
    .optional()
    .describe('YYYY-MM-DD, default today. Up to 15 days ahead.'),
  from: z
    .string()
    .regex(HHMM)
    .optional()
    .describe(
      'Hourly mode: start time HH:MM (default: now if today, else 06:00)',
    ),
  to: z
    .string()
    .regex(HHMM)
    .optional()
    .describe('Hourly mode: end time HH:MM (default 22:00)'),
  days: z
    .number()
    .int()
    .min(1)
    .max(16)
    .optional()
    .describe(
      'Daily mode: number of days starting at `date` (2..16). 1 or omitted = hourly for the date.',
    ),
});

export const weatherTool: ToolDef = {
  name: 'weather',
  description:
    'Weather forecast from Open-Meteo. Hourly within a time range for one date (default), or daily for up to 16 days (`days`). ' +
    'Needs a place name or lat/lon. There is NO default location: if the user did not name a place, call `location` first.',
  inputSchema: schema,
  kind: 'server',
  status: { de: 'Wetter wird abgefragt …', en: 'Checking the weather …' },
  async handler(args: z.infer<typeof schema>, { app }) {
    let lat = args.lat;
    let lon = args.lon;
    let label = '';
    if (args.place && (lat === undefined || lon === undefined)) {
      const g: any = await getJson(
        app.fetch,
        `https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(args.place)}&count=1&language=en&format=json`,
      );
      const r = g.results?.[0];
      if (!r)
        return `Place not found: "${args.place}". Try another spelling or pass lat/lon.`;
      lat = r.latitude;
      lon = r.longitude;
      label = [r.name, r.admin1, r.country].filter(Boolean).join(', ');
    } else if (lat !== undefined && lon !== undefined) {
      label = args.place ?? `${lat.toFixed(3)}, ${lon.toFixed(3)}`;
    } else {
      return NO_LOCATION;
    }

    const now = app.clock.now();
    const today = ymd(now);
    const date = args.date ?? today;
    const limit = ymd(now + 15 * 86_400_000);
    if (date < today || date > limit)
      return `Date ${date} is outside the forecast range (${today} .. ${limit}).`;

    const base = `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&timezone=auto&wind_speed_unit=kmh`;
    if ((args.days ?? 1) > 1) {
      const end = ymd(
        new Date(date + 'T12:00:00').getTime() + (args.days! - 1) * 86_400_000,
      );
      const endClamped = end > limit ? limit : end;
      const j: any = await getJson(
        app.fetch,
        `${base}&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,wind_speed_10m_max&start_date=${date}&end_date=${endClamped}`,
      );
      const d = j.daily;
      if (!d?.time) return 'The weather service returned no data.';
      const lines = d.time.map(
        (t: string, i: number) =>
          `${t}: ${wmo(d.weather_code[i])}, ${Math.round(d.temperature_2m_min[i])}..${Math.round(d.temperature_2m_max[i])} °C, ` +
          `rain ${d.precipitation_sum[i]} mm (${d.precipitation_probability_max[i] ?? '?'} %), wind max ${Math.round(d.wind_speed_10m_max[i])} km/h`,
      );
      return `Daily forecast for ${label}:\n${lines.join('\n')}`;
    }

    const j: any = await getJson(
      app.fetch,
      `${base}&hourly=temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,wind_speed_10m&start_date=${date}&end_date=${date}`,
    );
    const h = j.hourly;
    if (!h?.time) return 'The weather service returned no data.';
    const nowLocal = new Date(now);
    const fromStr =
      args.from ??
      (date === today ? `${pad(nowLocal.getHours())}:00` : '06:00');
    const toStr = args.to ?? '22:00';
    const toMin = (s: string) => {
      const m = HHMM.exec(s)!;
      return Number(m[1]) * 60 + Number(m[2]);
    };
    const a = toMin(fromStr);
    const b = Math.max(toMin(toStr), a);
    const step = (b - a) / 60 > 12 ? 2 : 1;
    const lines: string[] = [];
    let k = 0;
    h.time.forEach((t: string, i: number) => {
      const hhmm = t.slice(11, 16);
      const mins = toMin(hhmm);
      if (mins < Math.floor(a / 60) * 60 || mins > b) return;
      if (k++ % step !== 0) return;
      lines.push(
        `${hhmm} ${wmo(h.weather_code[i])}, ${Math.round(h.temperature_2m[i])} °C (feels ${Math.round(h.apparent_temperature[i])}), ` +
          `rain ${h.precipitation[i]} mm (${h.precipitation_probability[i] ?? '?'} %), wind ${Math.round(h.wind_speed_10m[i])} km/h`,
      );
    });
    if (!lines.length) return `No hourly data for ${date} ${fromStr}-${toStr}.`;
    return `Hourly forecast for ${label} on ${date} (${fromStr}-${toStr}, local time):\n${lines.join('\n')}`;
  },
};

async function getJson(f: typeof fetch, url: string): Promise<unknown> {
  const res = await f(url, { signal: AbortSignal.timeout(15_000) });
  if (!res.ok) throw new Error(`Weather service HTTP ${res.status}`);
  return res.json();
}
