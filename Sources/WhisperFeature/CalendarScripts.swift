/// Page scripts for `list_events`, run in the account's own page. Same
/// contract as `ServiceScripts`: `days` arrives as a JS variable, and the
/// script returns `JSON.stringify([{title, start, end, startMs, location,
/// organizer, join}])`.
///
/// Probed 2026-09-30:
/// - Teams: the page's MSAL cache holds a Microsoft Graph token with
///   Calendars.Read. It expires; the page's refresh token renews it at
///   login.microsoftonline.com exactly as Teams does.
/// - Meet: its home screen already shows the schedule (a week strip and a
///   "Scheduled" list per day). Meet loads it through an undocumented binary
///   RPC (`FetchUserAgenda`), so the script reads the rendered list instead:
///   each meeting's element id ends in its UTC start, `…_20260930T100000Z`.
/// - Slack has no calendar of its own.
enum CalendarScripts {
    static func script(for service: Service) -> String? {
        switch service {
        case .teams: teams
        case .meet: meet
        case .slack, .whatsapp, .custom: nil
        }
    }

    private static let teams = """
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const entries = () => Object.keys(localStorage)
      .map(k => { try { return JSON.parse(localStorage[k]) } catch (_) { return null } })
      .filter(v => v && v.credentialType);
    const graphAudience = jwt => {
      try {
        const aud = JSON.parse(atob(jwt.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))).aud;
        return aud === 'https://graph.microsoft.com' || aud === '00000003-0000-0000-c000-000000000000';
      } catch (_) { return false }
    };
    const live = v => Number(v.expiresOn) * 1000 > Date.now() + 60000;
    for (let i = 0; i < 60 && !/(^|\\.)teams\\.(microsoft\\.com|cloud\\.microsoft)$/.test(location.hostname); i++) await sleep(500);
    const retry = async (f, n = 3) => { for (let i = 1; ; i++) { try { return await f() } catch (e) { if (i >= n) throw new Error(e.message + ' (' + location.hostname + ')'); await sleep(1500) } } };
    let token = window.__whisperGraph && window.__whisperGraph.exp > Date.now() ? window.__whisperGraph.token : null;
    for (let i = 0; i < 60 && !token; i++) {
      const all = entries();
      // Graph's own token only: Teams also caches an Outlook-audience one with the same scopes, which Graph rejects (401).
      const cached = all.filter(v => v.credentialType === 'AccessToken' && /Calendars\\.Read/.test(v.target || '') && live(v)
          && graphAudience(v.secret))
        .sort((a, b) => Number(b.expiresOn) - Number(a.expiresOn))[0];
      if (cached) { token = cached.secret; break }
      const rt = all.find(v => v.credentialType === 'RefreshToken');
      const any = all.find(v => v.credentialType === 'AccessToken' && v.realm);
      if (rt && any) {
        const body = new URLSearchParams({client_id: rt.clientId, grant_type: 'refresh_token', refresh_token: rt.secret,
          scope: 'https://graph.microsoft.com/Calendars.Read openid profile offline_access'});
        const r = await retry(() => fetch(`https://login.microsoftonline.com/${any.realm}/oauth2/v2.0/token`,
          {method: 'POST', body, headers: {'content-type': 'application/x-www-form-urlencoded'}}));
        const j = await r.json();
        if (!r.ok) throw new Error('Teams calendar sign-in expired (' + (j.error || r.status) + '); open Teams in Whisper');
        token = j.access_token;
        window.__whisperGraph = {token, exp: Date.now() + (Number(j.expires_in) - 120) * 1000};
        break;
      }
      await sleep(500);
    }
    if (!token) throw new Error('Teams is not signed in');
    const start = new Date(), end = new Date(Date.now() + days * 864e5);
    const url = 'https://graph.microsoft.com/v1.0/me/calendarView?startDateTime=' + start.toISOString()
      + '&endDateTime=' + end.toISOString() + '&$top=200&$orderby=start/dateTime'
      + '&$select=subject,start,end,location,organizer,isOnlineMeeting,onlineMeeting,isCancelled';
    const r = await retry(() => fetch(url, {headers: {authorization: 'Bearer ' + token, prefer: 'outlook.timezone="UTC"'}}));
    if (!r.ok) throw new Error('Teams calendar ' + r.status);
    const utc = s => s ? s.replace(/(\\.\\d+)?$/, 'Z') : null;
    return JSON.stringify(((await r.json()).value || []).filter(e => !e.isCancelled).map(e => ({
      title: e.subject || '(no title)', start: utc(e.start?.dateTime), end: utc(e.end?.dateTime),
      startMs: Date.parse(utc(e.start?.dateTime)), location: e.location?.displayName || '',
      organizer: e.organizer?.emailAddress?.name || '', join: e.onlineMeeting?.joinUrl || ''})));
    """

    // ponytail: reads Meet's rendered week strip, so a Meet redesign breaks it; FetchUserAgenda is the upgrade if Google documents it.
    private static let meet = """
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    if (!/^\\/(home|landing)?\\/?$/.test(location.pathname))
      throw new Error('Google Meet is in a meeting right now; its schedule is on the home screen');
    // The 7 day buttons, found fresh each time (Meet re-renders the strip on week changes). Their text is
    // "WED 30", or "WED 30 Selected" for the chosen day; the month picker's buttons are bare numbers.
    const strip = () => [...document.querySelectorAll('button')]
      .filter(b => /^\\D+\\s+\\d{1,2}(\\s|$)/.test(b.innerText.trim().replace(/\\s+/g, ' ')));
    // Meet marks the chosen day with aria-pressed or aria-selected depending on the load path, so wait for the strip.
    for (let i = 0; i < 60 && strip().length !== 7; i++) await sleep(500);
    if (strip().length !== 7) throw new Error('Google Meet is not signed in, or its home screen did not load');
    const arrow = name => [...document.querySelectorAll('button')].find(b => b.innerText.includes(name));
    const scheduled = () => [...document.querySelectorAll('section ol li [role="button"][id]')];
    const clickAndSettle = async el => {
      const before = document.querySelector('section')?.parentElement?.parentElement?.innerHTML;
      el.click();
      for (let i = 0; i < 16; i++) {
        await sleep(250);
        if (document.querySelector('section')?.parentElement?.parentElement?.innerHTML !== before) break;
      }
      await sleep(300);
    };
    const start = new Date(); start.setHours(0, 0, 0, 0);
    const dow = start.getDay(), seen = new Map();
    let week = 0;
    for (let d = 0; d < days; d++) {
      const target = dow + d, w = Math.floor(target / 7);
      while (week < w) { const n = arrow('chevron_right'); if (!n) break; await clickAndSettle(n); week++ }
      const button = strip()[target % 7];
      if (!button) break;
      await clickAndSettle(button);
      const date = new Date(start.getTime() + d * 864e5);
      for (const el of scheduled()) {
        const m = el.id.match(/_(\\d{4})(\\d{2})(\\d{2})T(\\d{2})(\\d{2})(\\d{2})Z$/);
        if (!m || seen.has(el.id)) continue;
        const startMs = Date.UTC(+m[1], m[2] - 1, +m[3], +m[4], +m[5], +m[6]);
        const li = el.closest('li');
        const title = (li.querySelector('[role="heading"]')?.innerText || el.getAttribute('aria-label') || '').trim();
        const range = (li.innerText.match(/(\\d{1,2}:\\d{2}\\s*[AP]M)\\s*[–-]\\s*(\\d{1,2}:\\d{2}\\s*[AP]M)/i) || []);
        let end = null;
        if (range[2]) {
          const [, h, mi, ap] = range[2].match(/(\\d{1,2}):(\\d{2})\\s*([AP]M)/i);
          const e = new Date(date); e.setHours((+h % 12) + (/p/i.test(ap) ? 12 : 0), +mi, 0, 0);
          if (e.getTime() < startMs) e.setDate(e.getDate() + 1);
          end = e.toISOString();
        }
        seen.set(el.id, {title: title || '(no title)', start: new Date(startMs).toISOString(), end, startMs,
          location: '', organizer: '', join: ''});
      }
    }
    // Put the home screen back on today.
    while (week-- > 0) { const p = arrow('chevron_left'); if (!p) break; await clickAndSettle(p) }
    const back = strip()[dow]; if (back) back.click();
    return JSON.stringify([...seen.values()].filter(e => e.startMs >= Date.now() - 36e5));
    """
}
