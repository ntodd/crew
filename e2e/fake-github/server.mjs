// A fake github.com and api.github.com for end-to-end runs. No npm
// dependencies. It keeps state in memory, and tests drive and inspect it
// through /__fake/*.
//
//   CREW_BASE=http://localhost:4100 PORT=4199 node e2e/fake-github/server.mjs
//
// Where GitHub would redirect the browser to a URL built from the App's
// manifest (https://<tailnet host>/...), the fake keeps the path and
// sends the browser to CREW_BASE instead, since the tailnet host doesn't
// resolve in a test run.
import { createServer } from "node:http"
import { createHash, generateKeyPairSync, randomBytes } from "node:crypto"

const port = Number(process.env.PORT || 4199)
const crewBase = process.env.CREW_BASE || "http://localhost:4100"
const self = `http://localhost:${port}`

const fresh = () => ({
  manifests: {},       // state -> manifest
  apps: {},            // slug -> app
  conversions: {},     // code -> slug
  installations: [],   // {id, account, permissions, app_slug, repos: [...]}
  oauthCodes: {},      // code -> {challenge, user}
  tokens: {},          // access token -> user
  refreshTokens: {},   // refresh token -> user
  user: { id: 583231, login: "mona", name: "Mona Lisa", avatar_url: null },
  orgs: {},            // org -> [logins]
  requests: [],        // every API call, for assertions
})

let state = fresh()

const id = () => Math.floor(Math.random() * 1e9)
const token = prefix => prefix + randomBytes(18).toString("hex")

function send(res, status, body, headers = {}) {
  const json = typeof body !== "string"
  res.writeHead(status, {
    "content-type": json ? "application/json" : "text/html; charset=utf-8",
    ...headers,
  })
  res.end(json ? JSON.stringify(body) : body)
}

function redirect(res, location) {
  res.writeHead(302, { location })
  res.end()
}

// GitHub's own URL for something on the Crew side, rebased on CREW_BASE.
function toCrew(url, params) {
  const u = new URL(url)
  const target = new URL(u.pathname, crewBase)
  for (const [k, v] of Object.entries(params)) target.searchParams.set(k, v)
  return target.toString()
}

async function readBody(req) {
  const chunks = []
  for await (const chunk of req) chunks.push(chunk)
  const raw = Buffer.concat(chunks).toString()
  const type = req.headers["content-type"] || ""
  if (type.startsWith("application/x-www-form-urlencoded")) return Object.fromEntries(new URLSearchParams(raw))
  if (type.startsWith("application/json") && raw) return JSON.parse(raw)
  return raw
}

function page(title, body) {
  return `<!doctype html><html><head><title>${title} · Fake GitHub</title></head>
<body style="font-family: system-ui; margin: 3rem auto; max-width: 40rem">
<p style="color:#666">Fake GitHub</p><h1>${title}</h1>${body}</body></html>`
}

function escape(s) {
  return String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))
}

function bearer(req) {
  const auth = req.headers.authorization || ""
  return auth.startsWith("Bearer ") ? auth.slice(7) : auth.startsWith("token ") ? auth.slice(6) : null
}

const routes = []
const route = (method, pattern, handler) => routes.push({ method, pattern, handler })

// -- the App manifest flow ----------------------------------------------------

async function newApp(req, res, url) {
  const body = await readBody(req)
  const manifest = JSON.parse(body.manifest)
  const s = url.searchParams.get("state")
  state.manifests[s] = manifest
  send(res, 200, page(`Create GitHub App`, `
    <p>Name: <strong id="app-name">${escape(manifest.name)}</strong></p>
    <p>Webhook URL: <code id="hook-url">${escape(manifest.hook_attributes?.url)}</code></p>
    <p>Events: <code id="events">${escape((manifest.default_events || []).join(", "))}</code></p>
    <form method="get" action="/__fake/apps/create">
      <input type="hidden" name="state" value="${escape(s)}">
      <button type="submit">Create GitHub App for ${escape(manifest.name)}</button>
    </form>`))
}

route("POST", /^\/settings\/apps\/new$/, newApp)
route("POST", /^\/organizations\/[^/]+\/settings\/apps\/new$/, newApp)

route("GET", /^\/__fake\/apps\/create$/, (req, res, url) => {
  const s = url.searchParams.get("state")
  const manifest = state.manifests[s]
  if (!manifest) return send(res, 404, page("Unknown manifest", ""))
  const slug = manifest.name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "")
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 })
  const app = {
    id: id(),
    slug,
    name: manifest.name,
    client_id: "Iv1." + randomBytes(8).toString("hex"),
    client_secret: token(""),
    webhook_secret: token(""),
    pem: privateKey.export({ type: "pkcs1", format: "pem" }),
    html_url: `${self}/apps/${slug}`,
    manifest,
  }
  state.apps[slug] = app
  const code = token("")
  state.conversions[code] = slug
  redirect(res, toCrew(manifest.redirect_url, { code, state: s }))
})

route("POST", /^\/app-manifests\/([^/]+)\/conversions$/, (req, res, url, [, code]) => {
  const slug = state.conversions[code]
  if (!slug) return send(res, 404, { message: "Not Found" })
  delete state.conversions[code]
  const { manifest, ...app } = state.apps[slug]
  send(res, 201, { ...app, owner: { login: state.user.login } })
})

route("GET", /^\/apps\/([^/]+)\/installations\/new$/, (req, res, url, [, slug]) => {
  const app = state.apps[slug]
  if (!app) return send(res, 404, page("Unknown app", ""))
  send(res, 200, page(`Install ${escape(app.name)}`, `
    <form method="get" action="/__fake/apps/${escape(slug)}/install">
      <button type="submit">Install</button>
    </form>`))
})

route("GET", /^\/__fake\/apps\/([^/]+)\/install$/, (req, res, url, [, slug]) => {
  const app = state.apps[slug]
  const installation = {
    id: id(),
    app_slug: slug,
    account: { login: state.user.login, id: state.user.id, type: "User" },
    permissions: app.manifest.default_permissions,
    repos: [],
  }
  state.installations.push(installation)
  redirect(res, toCrew(app.manifest.setup_url, { installation_id: installation.id, setup_action: "install" }))
})

// -- user OAuth -----------------------------------------------------------------

route("GET", /^\/login\/oauth\/authorize$/, (req, res, url) => {
  const code = token("")
  state.oauthCodes[code] = {
    challenge: url.searchParams.get("code_challenge"),
    client_id: url.searchParams.get("client_id"),
    user: state.user,
  }
  redirect(res, toCrew(url.searchParams.get("redirect_uri"), { code, state: url.searchParams.get("state") }))
})

route("POST", /^\/login\/oauth\/access_token$/, async (req, res) => {
  const form = await readBody(req)

  if (form.grant_type === "refresh_token") {
    const user = state.refreshTokens[form.refresh_token]
    if (!user) return send(res, 200, { error: "bad_refresh_token" })
    delete state.refreshTokens[form.refresh_token]
    return send(res, 200, issue(user))
  }

  const grant = state.oauthCodes[form.code]
  if (!grant) return send(res, 200, { error: "bad_verification_code" })
  const challenge = createHash("sha256").update(form.code_verifier || "").digest("base64url")
  if (challenge !== grant.challenge) return send(res, 200, { error: "bad_verification_code", detail: "PKCE" })
  delete state.oauthCodes[form.code]
  send(res, 200, issue(grant.user))
})

function issue(user) {
  const access = token("ghu_")
  const refresh = token("ghr_")
  state.tokens[access] = user
  state.refreshTokens[refresh] = user
  return { access_token: access, refresh_token: refresh, expires_in: 28800, refresh_token_expires_in: 15897600, token_type: "bearer" }
}

route("GET", /^\/user$/, (req, res) => {
  const user = state.tokens[bearer(req)]
  if (!user) return send(res, 401, { message: "Bad credentials" })
  send(res, 200, user)
})

route("GET", /^\/user\/memberships\/orgs\/([^/]+)$/, (req, res, url, [, org]) => {
  const user = state.tokens[bearer(req)]
  if (!user) return send(res, 401, { message: "Bad credentials" })
  const members = state.orgs[org]
  if (members && members.includes(user.login)) return send(res, 200, { state: "active" })
  send(res, 404, { message: "Not Found" })
})

route("GET", /^\/orgs\/([^/]+)$/, (req, res, url, [, org]) => {
  state.orgs[org] ? send(res, 200, { login: org }) : send(res, 404, { message: "Not Found" })
})

// -- control ------------------------------------------------------------------------

route("GET", /^\/__fake\/state$/, (req, res) => send(res, 200, state))
route("POST", /^\/__fake\/reset$/, (req, res) => { state = fresh(); send(res, 200, { ok: true }) })
route("POST", /^\/__fake\/user$/, async (req, res) => {
  state.user = { ...state.user, ...(await readBody(req)) }
  send(res, 200, state.user)
})

createServer(async (req, res) => {
  const url = new URL(req.url, self)
  if (!url.pathname.startsWith("/__fake")) {
    state.requests.push({ method: req.method, path: url.pathname, at: Date.now() })
  }
  for (const r of routes) {
    const m = r.method === req.method && url.pathname.match(r.pattern)
    if (m) {
      try {
        return await r.handler(req, res, url, m)
      } catch (e) {
        console.error(e)
        return send(res, 500, { message: String(e) })
      }
    }
  }
  send(res, 404, { message: `Not Found (fake: ${req.method} ${url.pathname})` })
}).listen(port, "127.0.0.1", () => console.log(`fake GitHub on ${self}, sending browsers to ${crewBase}`))
