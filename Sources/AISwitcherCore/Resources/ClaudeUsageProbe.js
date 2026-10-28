// Read-only usage request in the same web session; no chat or model request is made.
if (location.origin !== "https://claude.ai" || !/^[0-9a-f-]{36}$/i.test(organizationID)) return "{}";
try {
  const controller = new AbortController(); globalThis.__aiswUsageProbeController = controller; const timer = setTimeout(() => controller.abort(), 10000);
  let response, raw;
  try { response = await fetch("/api/organizations/" + encodeURIComponent(organizationID) + "/usage", {credentials: "same-origin", cache: "no-store", signal: controller.signal}); if (response.ok) raw = await response.json(); }
  finally { clearTimeout(timer); }
  if (!response.ok) return "{}";
  const limits = {};
  for (const key of ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps"]) {
    const value = raw[key];
    if (value && typeof value.utilization === "number") limits[key] = {utilization: value.utilization, resets_at: typeof value.resets_at === "string" ? value.resets_at.slice(0, 80) : null};
  }
  return JSON.stringify({rate_limits_available: Object.keys(limits).length > 0, rate_limits: limits});
} catch { return "{}"; }
