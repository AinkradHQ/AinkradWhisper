/// The page scripts behind the assistant tools, one prelude per service plus
/// one body per operation. Each runs through `callAsyncJavaScript`, so its
/// inputs (`limit`, `chat`, `query`, `text`) are real JS variables and it must
/// `return JSON.stringify(…)`.
///
/// Slack and Teams use the signed-in page's own token against their web APIs;
/// WhatsApp has no API, so it drives the page. Recipes from the 2026-09-29 spike.
enum ServiceScripts {
    enum Operation: CaseIterable {
        case listChats, readMessages, search, send

        /// String arguments the operation needs besides `limit`.
        var required: [String] {
            switch self {
            case .listChats: []
            case .readMessages: ["chat"]
            case .search: ["query"]
            case .send: ["chat", "text"]
            }
        }
    }

    static func script(_ operation: Operation, for service: Service) -> String? {
        switch service {
        case .slack: common + slack + slackBody(operation)
        case .teams: common + teams + teamsBody(operation)
        case .whatsapp: common + whatsapp + whatsappBody(operation)
        case .custom: nil
        }
    }

    private static let common = """
    const sleep = ms => new Promise(r => setTimeout(r, ms));

    """

    // MARK: Slack

    private static let slack = """
    let team;
    for (let i = 0; i < 60 && !team; i++) {
      try {
        const teams = Object.values(JSON.parse(localStorage.localConfig_v2 || '{}').teams || {});
        team = teams.find(t => t.id === location.pathname.split('/')[2]) || teams[0];
      } catch (_) {}
      if (!team) await sleep(500);
    }
    if (!team) throw new Error('Slack is not signed in');
    const api = async (method, params = {}) => {
      const form = new FormData();
      form.append('token', team.token);
      for (const k in params) form.append(k, params[k]);
      const res = await (await fetch('/api/' + method, {method: 'POST', body: form, credentials: 'include'})).json();
      if (!res.ok) throw new Error(method + ': ' + res.error);
      return res;
    };
    const names = {};
    const userName = async id => {
      if (!id) return '';
      if (!(id in names)) {
        try { const u = (await api('users.info', {user: id})).user; names[id] = u.profile?.display_name || u.real_name || u.name }
        catch (_) { names[id] = id }
      }
      return names[id];
    };
    const at = ts => new Date(parseFloat(ts) * 1000).toISOString();
    const conversations = async () =>
      (await api('conversations.list', {limit: 1000, exclude_archived: true, types: 'public_channel,private_channel,mpim,im'}))
        .channels.filter(c => c.is_member || c.is_im);
    const chatID = async ref => {
      if (/^[CDG][A-Z0-9]{6,}$/.test(ref)) return ref;
      const want = ref.replace(/^[#@]/, '').toLowerCase();
      for (const c of await conversations()) {
        if ((c.name || '').toLowerCase() === want) return c.id;
        if (c.is_im && (await userName(c.user)).toLowerCase() === want) return c.id;
      }
      throw new Error('No Slack chat named ' + ref);
    };

    """

    private static func slackBody(_ operation: Operation) -> String {
        switch operation {
        case .listChats: """
            const chats = await Promise.all((await conversations()).slice(0, limit).map(async c => ({
              id: c.id, name: c.is_im ? '@' + await userName(c.user) : '#' + (c.name || c.id),
              kind: c.is_im ? 'dm' : c.is_mpim ? 'group' : 'channel'})));
            return JSON.stringify(chats);
            """
        case .readMessages: """
            const channel = await chatID(chat);
            const out = [];
            for (const m of (await api('conversations.history', {channel, limit})).messages.reverse())
              out.push({from: m.user ? await userName(m.user) : (m.username || m.bot_profile?.name || ''), at: at(m.ts), text: m.text});
            return JSON.stringify({chat: channel, messages: out});
            """
        case .search: """
            const res = await api('search.messages', {query, count: limit, sort: 'timestamp', sort_dir: 'desc'});
            return JSON.stringify(res.messages.matches.map(m => ({
              chat: m.channel?.name ? '#' + m.channel.name : m.channel?.id, chatID: m.channel?.id,
              from: m.username, at: at(m.ts), text: m.text})));
            """
        case .send: """
            const channel = await chatID(chat);
            const res = await api('chat.postMessage', {channel, text});
            return JSON.stringify({sent: true, chat: channel, ts: res.ts});
            """
        }
    }

    // MARK: Teams

    private static let teams = """
    const tokens = () => Object.keys(localStorage)
      .map(k => { try { return JSON.parse(localStorage[k]) } catch (_) { return null } })
      .filter(v => v && v.credentialType === 'AccessToken' && /ic3\\.teams\\.office\\.com/.test(v.target || '')
        && Number(v.expiresOn) * 1000 > Date.now() + 60000)
      .sort((a, b) => Number(b.expiresOn) - Number(a.expiresOn));
    let tok;
    for (let i = 0; i < 60 && !tok; i++) { tok = tokens()[0]; if (!tok) await sleep(500) }
    if (!tok) throw new Error('Teams is not signed in (no chat token yet)');
    const me = '8:orgid:' + (tok.homeAccountId || '').split('.')[0];
    const headers = {authorization: 'Bearer ' + tok.secret, 'content-type': 'application/json'};
    let base = window.__whisperTeamsBase;
    if (!base) for (const region of ['emea', 'amer', 'apac']) {
      const b = `https://teams.cloud.microsoft/api/chatsvc/${region}/v1/users/ME/conversations`;
      if ((await fetch(b + '?view=msnp24Equivalent&pageSize=1', {headers})).ok) { base = window.__whisperTeamsBase = b; break }
    }
    if (!base) throw new Error('Teams chat service unreachable');
    const get = async path => { const r = await fetch(base + path, {headers}); if (!r.ok) throw new Error('Teams ' + r.status); return r.json() };
    const strip = h => (h || '').replace(/<br\\s*\\/?>/gi, '\\n').replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ')
      .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&').trim();
    const messages = async id => ((await get(`/${encodeURIComponent(id)}/messages?pageSize=${limit}&view=msnp24Equivalent`)).messages || [])
      .filter(m => /^(Text|RichText)/.test(m.messagetype || ''));
    const nameOf = async c => {
      if (c.id === '48:notes') return 'Notes to self';
      if (c.threadProperties?.topic) return c.threadProperties.topic;
      const other = (await messages(c.id)).find(m => m.imdisplayname && !(m.from || '').endsWith(me));
      return other ? other.imdisplayname : c.id;
    };
    const chats = async n => Promise.all(((await get(`?view=msnp24Equivalent&pageSize=${n}`)).conversations || []).map(async c => ({
      id: c.id, name: await nameOf(c), last: strip(c.lastMessage?.content).slice(0, 160),
      at: c.lastMessage?.originalarrivaltime || c.lastMessage?.composetime})));
    const chatID = async ref => {
      if (ref.includes(':')) return ref;
      const hit = (await chats(100)).find(c => c.name.toLowerCase() === ref.toLowerCase());
      if (!hit) throw new Error('No Teams chat named ' + ref);
      return hit.id;
    };

    """

    private static func teamsBody(_ operation: Operation) -> String {
        switch operation {
        case .listChats: """
            return JSON.stringify(await chats(limit));
            """
        case .readMessages: """
            const id = await chatID(chat);
            return JSON.stringify({chat: id, messages: (await messages(id)).reverse().map(m => ({
              from: m.imdisplayname || '', at: m.originalarrivaltime, text: strip(m.content)}))});
            """
        case .search: """
            const q = query.toLowerCase();
            return JSON.stringify((await chats(100)).filter(c => c.name.toLowerCase().includes(q) || c.last.toLowerCase().includes(q)).slice(0, limit));
            """
        case .send: """
            const id = await chatID(chat);
            const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\\n/g, '<br>');
            const r = await fetch(`${base}/${encodeURIComponent(id)}/messages`, {method: 'POST', headers, body: JSON.stringify({
              content: '<p>' + esc(text) + '</p>', messagetype: 'RichText/Html', contenttype: 'text',
              clientmessageid: String(Date.now()) + String(Math.floor(Math.random() * 1e6))})});
            if (!r.ok) throw new Error('Teams send failed: ' + r.status);
            return JSON.stringify({sent: true, chat: id});
            """
        }
    }

    // MARK: WhatsApp

    private static let whatsapp = """
    for (let i = 0; i < 60 && !document.querySelector('#pane-side'); i++) await sleep(500);
    if (!document.querySelector('#pane-side')) throw new Error('WhatsApp is not signed in (scan the QR code in Whisper)');
    const rows = () => [...document.querySelectorAll('#pane-side [role="row"], #pane-side [role="listitem"]')];
    const titleOf = r => r.querySelector('span[title]')?.getAttribute('title') || r.innerText.split('\\n')[0];
    const chatRows = () => rows().map(r => ({name: titleOf(r), last: r.innerText.split('\\n').filter(Boolean).slice(1).join(' ').slice(0, 160)}));
    const open = async name => {
      const want = name.toLowerCase();
      const row = rows().find(r => titleOf(r).toLowerCase() === want) || rows().find(r => titleOf(r).toLowerCase().includes(want));
      if (!row) throw new Error('No WhatsApp chat named "' + name + '" in the recent list');
      const title = titleOf(row);
      const target = row.querySelector('span[title]') || row;
      for (const t of ['mousedown', 'mouseup', 'click']) target.dispatchEvent(new MouseEvent(t, {bubbles: true}));
      for (let i = 0; i < 20; i++) {
        await sleep(250);
        const header = (document.querySelector('#main header')?.innerText.split('\\n')[0] || '').toLowerCase();
        if (header && (header.includes(title.toLowerCase()) || title.toLowerCase().includes(header))) return title;
      }
      throw new Error('Could not open WhatsApp chat "' + title + '"');
    };

    """

    private static func whatsappBody(_ operation: Operation) -> String {
        switch operation {
        case .listChats: """
            return JSON.stringify(chatRows().slice(0, limit));
            """
        case .readMessages: """
            const title = await open(chat);
            await sleep(500);
            const out = [...document.querySelectorAll('#main [role="row"]')].slice(-limit).map(r => {
              const meta = r.querySelector('[data-pre-plain-text]');
              const m = (meta?.getAttribute('data-pre-plain-text') || '').match(/^\\[([^\\]]+)\\]\\s*([^:]*):/);
              const text = (meta?.querySelector('.selectable-text')?.innerText || r.innerText).trim();
              return {from: m ? m[2].trim() : '', at: m ? m[1] : '', text};
            }).filter(m => m.text);
            return JSON.stringify({chat: title, messages: out});
            """
        case .search: """
            const q = query.toLowerCase();
            return JSON.stringify(chatRows().filter(c => c.name.toLowerCase().includes(q) || c.last.toLowerCase().includes(q)).slice(0, limit));
            """
        case .send: """
            const title = await open(chat);
            const box = document.querySelector('#main footer [contenteditable="true"]');
            if (!box) throw new Error('WhatsApp compose box not found');
            box.focus();
            document.execCommand('insertText', false, text);
            await sleep(400);
            const button = document.querySelector('#main footer button[aria-label="Send"]')
              || document.querySelector('#main footer span[data-icon="send"], #main footer span[data-icon="wds-ic-send-filled"]')?.closest('button');
            if (!button) throw new Error('WhatsApp send button not found');
            button.click();
            return JSON.stringify({sent: true, chat: title});
            """
        }
    }
}
