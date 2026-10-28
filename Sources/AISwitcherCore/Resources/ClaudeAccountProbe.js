// Runs in the authenticated page. It returns public account metadata only, never cookies or credentials.
if (location.origin !== "https://claude.ai") return JSON.stringify({state: "signedOut"});
const read = async path => {
  const controller = new AbortController(); globalThis.__aiswAccountProbeController = controller;
  const timer = setTimeout(() => controller.abort(), 10000);
  try { const response = await fetch(path, {credentials: "same-origin", cache: "no-store", signal: controller.signal});
    return {status: response.status, ok: response.ok, data: response.ok ? await response.json() : null};
  } finally { clearTimeout(timer); }
};
try {
  const response = await read("/api/account");
  if (response.status === 401 || response.status === 403) return JSON.stringify({state: "signedOut"});
  if (!response.ok) return JSON.stringify({state: "unavailable"});
  const raw = response.data;
  const a = raw.account || raw;
  if (typeof a.email_address !== "string" || typeof a.uuid !== "string") return JSON.stringify({state: "unavailable"});
  let organizations = Array.isArray(a.memberships) ? a.memberships.map(m => m.organization).filter(Boolean) : [];
  if (!organizations.length || organizations.some(o => !Array.isArray(o.capabilities) && typeof o.plan_display_name !== "string" && typeof o.subscription_type !== "string")) {
    const orgResponse = await read("/api/organizations");
    if (orgResponse.ok) {
      const list = Array.isArray(orgResponse.data) ? orgResponse.data : orgResponse.data?.organizations;
      if (Array.isArray(list)) organizations = organizations.length ? organizations.map(o => ({...o, ...list.find(x => x.uuid === o.uuid)})) : list;
    }
  }
  const clean = o => {
    const result = {};
    for (const k of ["uuid", "billing_type", "raven_type", "plan_display_name", "subscription_type"]) {
      if (o[k] === null || typeof o[k] === "string") result[k] = o[k] === null ? null : o[k].slice(0, 100);
    }
    if (Array.isArray(o.capabilities)) result.capabilities = o.capabilities.filter(x => typeof x === "string").slice(0, 64).map(x => x.slice(0, 100));
    return result;
  };
  return JSON.stringify({state: "ok", account: {uuid: a.uuid.slice(0, 80), email_address: a.email_address.slice(0, 320), subscription_type: typeof a.subscription_type === "string" ? a.subscription_type.slice(0, 64) : null}, organizations: organizations.slice(0, 20).map(clean)});
} catch { return JSON.stringify({state: "unavailable"}); }
