// Test double only: does not load Hermes, contact a model, or change an agent profile.
'use strict';
const http = require('node:http');
const crypto = require('node:crypto');
const host = process.env.HES_FIXTURE_HOST;
const password = process.env.HES_FIXTURE_PASSWORD;
const profile = 'infonet-fixture';
if (!host || !password) process.exit(2);
const session = crypto.randomBytes(24).toString('hex');
const state = {soul: 'Original fixture identity.', env: {}, restarts: 0, deleted: [], profiles: []};
const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://fixture.invalid');
    const send = (code, value, headers = {}) => { res.writeHead(code, {'Content-Type': 'application/json', ...headers}); res.end(JSON.stringify(value)); };
    try {
        const chunks = []; let size = 0;
        for await (const chunk of req) { size += chunk.length; if (size > 32768) return send(413, {}); chunks.push(chunk); }
        const raw = Buffer.concat(chunks).toString('utf8');
        const body = raw ? JSON.parse(raw) : {};
        if (url.pathname === '/api/status') return send(200, {status: 'ok', auth_required: true});
        if (url.pathname === '/auth/password-login') {
            if (body.provider !== 'basic' || body.username !== 'admin' || body.password !== password) return send(401, {ok: false});
            return send(200, {ok: true}, {'Set-Cookie': `session=${session}; HttpOnly; Path=/`});
        }
        if (url.pathname === '/__fixture/state') {
            if (req.headers.authorization !== `Bearer ${password}`) return send(401, {});
            return send(200, state);
        }
        if (!(req.headers.cookie || '').split(';').map(x => x.trim()).includes(`session=${session}`)) return send(401, {});
        if (url.pathname === '/api/auth/me') return send(200, {user_id: 'admin'});
        const soulPath = `/api/profiles/${profile}/soul`;
        const selected = url.pathname === soulPath ? profile : (url.searchParams.get('profile') || body.profile);
        if (selected !== profile) return send(400, {error: 'profile mismatch'});
        state.profiles.push(selected);
        if (url.pathname === soulPath) {
            if (req.method === 'PUT') state.soul = body.content;
            return send(200, {content: state.soul, exists: true});
        }
        if (url.pathname === '/api/env' && req.method === 'PUT') { state.env[body.key] = body.value; return send(200, {ok: true}); }
        if (url.pathname === '/api/sessions') return send(200, {sessions: [{id: 'fixture-open', ended_at: null}, {id: 'fixture-ended', ended_at: 123}], total: 2});
        if (url.pathname === '/api/sessions/bulk-delete') { state.deleted.push(...body.ids); return send(200, {deleted: body.ids.length}); }
        if (url.pathname === '/api/gateway/restart') { state.restarts++; return send(200, {ok: true}); }
        return send(404, {});
    } catch { return send(400, {error: 'invalid fixture request'}); }
});
server.on('error', () => process.exit(3));
server.listen(0, host, () => process.stdout.write(JSON.stringify({port: server.address().port}) + '\n'));
