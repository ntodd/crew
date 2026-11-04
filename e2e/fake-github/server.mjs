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
import { createHash, createHmac, generateKeyPairSync, randomBytes, randomUUID } from "node:crypto"

const port = Number(process.env.PORT || 4199)
const crewBase = process.env.CREW_BASE || "http://localhost:4100"
const crewHook = process.env.CREW_HOOK || "http://127.0.0.1:4101/hooks/github"
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
  installationTokens: {}, // token -> installation id
  repos: [],           // {id, full_name, private, default_branch, installation_id, archived}
  runs: [],            // {id, run_attempt, repo_id, ...}
  jobs: [],            // {id, run_id, run_attempt, ...}
  deliveries: [],      // {id, guid, event, action, status_code, delivered_at, redelivery, payload}
  dropNext: 0,         // fail this many outgoing deliveries (as if Crew were down)
  cancelled: [],       // run ids
  runners: [],         // {id, name, labels, repo_id, busy, job_id, listening}
  requests: [],        // every API call, for assertions
  // Crew's own releases (§20.3), for the Deployment page's update check:
  // one newer than the dev control plane's 0.1.0, and the kinds it
  // passes over. POST /__fake/releases replaces them.
  crewReleases: [
    {tag_name: "v0.3.0-rc.1", draft: false, prerelease: true},
    {tag_name: "v9.9.9", draft: true, prerelease: false},
    {tag_name: "v0.2.0", draft: false, prerelease: false},
    {tag_name: "v0.1.0", draft: false, prerelease: false},
  ].map(r => ({...r, html_url: `${self}/ntodd/crew/releases/tag/${r.tag_name}`})),
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
  // GitHub pings a new App's webhook. Crew doesn't have the secret until
  // the conversion, so this one fails (as it can on GitHub, too).
  setTimeout(() => deliver("ping", { zen: "Speak like a human.", hook_id: 1, hook: { type: "App" } }), 50)
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
  setTimeout(() => deliver("installation", { action: "created", installation: installationJson(installation), repositories: [] }), 50)
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

// -- installations, repos, runs and jobs (the API) ------------------------------------

const app = () => Object.values(state.apps)[0]
const installationFor = id => state.installations.find(i => String(i.id) === String(id))
const repoByName = (o, r) => state.repos.find(x => x.full_name === `${o}/${r}`)
const repoJson = r => ({ id: r.id, name: r.full_name.split("/")[1], full_name: r.full_name, private: r.private, default_branch: r.default_branch, archived: !!r.archived, owner: { login: r.full_name.split("/")[0] } })
const installationJson = i => ({ id: i.id, account: i.account, permissions: i.permissions, app_slug: i.app_slug })

route("GET", /^\/app\/installations$/, (req, res) => send(res, 200, state.installations.map(installationJson)))
route("GET", /^\/app\/installations\/(\d+)$/, (req, res, url, [, id]) => {
  const i = installationFor(id)
  i ? send(res, 200, installationJson(i)) : send(res, 404, { message: "Not Found" })
})
route("POST", /^\/app\/installations\/(\d+)\/access_tokens$/, (req, res, url, [, id]) => {
  const t = token("ghs_")
  state.installationTokens[t] = Number(id)
  send(res, 201, { token: t, expires_at: new Date(Date.now() + 3600e3).toISOString() })
})
route("GET", /^\/installation\/repositories$/, (req, res) => {
  const id = state.installationTokens[bearer(req)]
  if (!id) return send(res, 401, { message: "Bad credentials" })
  const repos = state.repos.filter(r => r.installation_id === id).map(repoJson)
  send(res, 200, { total_count: repos.length, repositories: repos })
})
route("GET", /^\/user\/installations\/(\d+)\/repositories$/, (req, res, url, [, id]) => {
  if (!state.tokens[bearer(req)]) return send(res, 401, { message: "Bad credentials" })
  const repos = state.repos.filter(r => r.installation_id === Number(id)).map(r => ({ ...repoJson(r), permissions: { pull: true, push: true } }))
  send(res, 200, { total_count: repos.length, repositories: repos })
})

const runJson = run => {
  const repo = state.repos.find(r => r.id === run.repo_id)
  return {
    id: run.id, run_attempt: run.run_attempt, run_number: run.run_number, name: run.name, event: run.event,
    status: run.status, conclusion: run.conclusion, head_branch: run.head_branch, head_sha: run.head_sha,
    head_commit: { message: run.message }, actor: { login: state.user.login, id: state.user.id },
    pull_requests: run.pull_requests || [], head_repository: run.head_repo ? { full_name: run.head_repo } : null,
    created_at: run.created_at, updated_at: run.updated_at, repository: repoJson(repo),
  }
}
const jobJson = job => ({
  id: job.id, run_id: job.run_id, run_attempt: job.run_attempt, name: job.name, workflow_name: job.workflow_name,
  labels: job.labels, status: job.status, conclusion: job.conclusion, created_at: job.created_at,
  started_at: job.started_at, completed_at: job.completed_at, runner_name: job.runner_name, runner_id: job.runner_id,
  head_branch: job.head_branch, head_sha: job.head_sha, steps: job.steps || [],
})

route("GET", /^\/repos\/([^/]+)\/([^/]+)\/actions\/runs\/(\d+)\/attempts\/(\d+)$/, (req, res, url, [, o, r, id, n]) => {
  const run = state.runs.find(x => x.id === Number(id) && x.run_attempt === Number(n))
  run ? send(res, 200, runJson(run)) : send(res, 404, { message: "Not Found" })
})
route("GET", /^\/repos\/([^/]+)\/([^/]+)\/actions\/runs\/(\d+)\/attempts\/(\d+)\/jobs$/, (req, res, url, [, o, r, id, n]) => {
  const jobs = state.jobs.filter(j => j.run_id === Number(id) && j.run_attempt === Number(n)).map(jobJson)
  send(res, 200, { total_count: jobs.length, jobs })
})
// actions/runner's releases (§13.1): a newer runner than the e2e image's
// came out 16 days ago, so the Images page warns.
route("GET", /^\/repos\/actions\/runner\/releases$/, (req, res) => {
  const ago = days => new Date(Date.now() - days * 86_400_000).toISOString()
  send(res, 200, [
    {tag_name: "v2.339.0", published_at: ago(16), draft: false, prerelease: false},
    {tag_name: "v2.338.2", published_at: ago(40), draft: false, prerelease: false},
  ])
})
// Any other repo's releases are Crew's own (CREW_UPDATE_REPO).
route("GET", /^\/repos\/([^/]+)\/([^/]+)\/releases$/, (req, res) => send(res, 200, state.crewReleases))
route("GET", /^\/repos\/([^/]+)\/([^/]+)\/actions\/runs$/, (req, res, url, [, o, r]) => {
  const repo = repoByName(o, r)
  const status = url.searchParams.get("status")
  const runs = state.runs.filter(x => repo && x.repo_id === repo.id && (!status || x.status === status)).map(runJson)
  send(res, 200, { total_count: runs.length, workflow_runs: runs })
})
route("GET", /^\/repos\/([^/]+)\/([^/]+)\/actions\/jobs\/(\d+)$/, (req, res, url, [, o, r, id]) => {
  const job = state.jobs.find(j => j.id === Number(id))
  job ? send(res, 200, jobJson(job)) : send(res, 404, { message: "Not Found" })
})
route("POST", /^\/repos\/([^/]+)\/([^/]+)\/actions\/runs\/(\d+)\/cancel$/, async (req, res, url, [, o, r, id]) => {
  state.cancelled.push(Number(id))
  send(res, 202, {})
})

// -- self-hosted runners (JIT) -----------------------------------------------------------
//
// A JIT config here is base64 JSON: ".runner" is what crew-guest checks
// (DisableUpdate), and "fake" tells the null driver's fake guest where to
// ask for a job. GitHub gives a runner any queued job of its repo whose
// labels are all among the runner's; the fake does the same, oldest first.

const runnerJson = r => ({ id: r.id, name: r.name, os: "linux", status: r.listening ? "online" : "offline", busy: r.busy,
  labels: r.labels.map(name => ({ id: 1, name, type: "custom" })) })

route("POST", /^\/repos\/([^/]+)\/([^/]+)\/actions\/runners\/generate-jitconfig$/, async (req, res, url, [, o, r]) => {
  const repo = repoByName(o, r)
  const b = await readBody(req)
  if (!repo) return send(res, 404, { message: "Not Found" })
  if (state.runners.some(x => x.name === b.name)) return send(res, 409, { message: "Already exists - A runner with the name already exists." })
  const runner = { id: id(), name: b.name, labels: b.labels || [], repo_id: repo.id, busy: false, job_id: null, listening: false }
  state.runners.push(runner)
  const inner = Buffer.from(JSON.stringify({ AgentName: b.name, DisableUpdate: true })).toString("base64")
  const jit = Buffer.from(JSON.stringify({ ".runner": inner, fake: { name: b.name, api: self } })).toString("base64")
  send(res, 201, { runner: runnerJson(runner), encoded_jit_config: jit })
})

route("GET", /^\/repos\/([^/]+)\/([^/]+)\/actions\/runners$/, (req, res, url, [, o, r]) => {
  const repo = repoByName(o, r)
  const runners = state.runners.filter(x => repo && x.repo_id === repo.id).map(runnerJson)
  send(res, 200, { total_count: runners.length, runners })
})

route("DELETE", /^\/repos\/([^/]+)\/([^/]+)\/actions\/runners\/(\d+)$/, (req, res, url, [, o, r, rid]) => {
  const runner = state.runners.find(x => x.id === Number(rid))
  if (!runner) return send(res, 404, { message: "Not Found" })
  if (runner.busy) return send(res, 422, { message: "Bad request - Runner \"" + runner.name + "\" is still running a job\"" })
  state.runners = state.runners.filter(x => x !== runner)
  res.writeHead(204)
  res.end()
})

async function assign(runner) {
  const queued = state.jobs
    .filter(j => j.status === "queued" && !j.hold)
    .filter(j => { const run = state.runs.find(x => x.id === j.run_id && x.run_attempt === j.run_attempt); return run && run.repo_id === runner.repo_id })
    .filter(j => j.labels.every(l => runner.labels.includes(l)))
    .sort((a, b) => a.created_at.localeCompare(b.created_at) || a.id - b.id)
  const job = queued[0]
  if (!job) return null
  runner.busy = true
  runner.job_id = job.id
  await moveJob(job, { status: "in_progress", runner_name: runner.name, runner_id: runner.id })
  return job
}

// The fake guest's long poll: a job for this runner, or 204 after `wait` s.
route("GET", /^\/__fake\/runners\/([^/]+)\/job$/, async (req, res, url, [, name]) => {
  const until = Date.now() + 1000 * Number(url.searchParams.get("wait") || 20)
  for (;;) {
    const runner = state.runners.find(x => x.name === name)
    if (!runner) return send(res, 410, { message: "runner deleted" })
    runner.listening = true
    if (runner.job_id) return send(res, 200, jobJson(state.jobs.find(j => j.id === runner.job_id)))
    const job = await assign(runner)
    if (job) return send(res, 200, { ...jobJson(job), seconds: job.seconds ?? null, exit: job.exit ?? 0, log: job.log ?? null, log_lines: job.log_lines ?? 0 })
    if (Date.now() > until) { res.writeHead(204); return res.end() }
    await new Promise(r => setTimeout(r, 100))
  }
})

// The fake guest finished its job: completed, and the ephemeral runner goes.
route("POST", /^\/__fake\/runners\/([^/]+)\/done$/, async (req, res, url, [, name]) => {
  const b = await readBody(req)
  const runner = state.runners.find(x => x.name === name)
  if (!runner || !runner.job_id) return send(res, 404, { message: "no job" })
  const job = state.jobs.find(j => j.id === runner.job_id)
  state.runners = state.runners.filter(x => x !== runner)
  finalLog(job, b.conclusion || "success")
  await moveJob(job, { status: "completed", conclusion: b.conclusion || "success" })
  send(res, 200, jobJson(job))
})

// The job's steps and the plain-text log GitHub would have once it's done:
// timestamped lines, with the rich log's groups, colours and annotations.
function finalLog(job, conclusion) {
  const start = Date.parse(job.started_at || new Date().toISOString())
  const iso = ms => new Date(ms).toISOString().replace("Z", "0000Z")
  const setupEnd = start + 1000
  const end = Date.now()
  job.steps = [
    { name: "Set up job", number: 1, status: "completed", conclusion: "success", started_at: new Date(start).toISOString(), completed_at: new Date(setupEnd).toISOString() },
    { name: "Run tests", number: 2, status: "completed", conclusion, started_at: new Date(setupEnd).toISOString(), completed_at: new Date(end).toISOString() },
  ]
  const lines = [[start + 10, "Current runner version: '2.330.0'"], [start + 20, "##[group]Operating System"], [start + 30, "Ubuntu 24.04"], [start + 40, "##[endgroup]"]]
  const t = setupEnd + 10
  lines.push([t, "\u001b[32mgreen\u001b[0m from GitHub's log"])
  if (job.log === "rich") {
    lines.push([t, "a needle in the haystack"])
    for (let i = 1; i <= (job.log_lines || 0); i++) lines.push([t, `filler line ${i} of GitHub's log`])
    if (conclusion !== "success") lines.push([t, "##[error]Process completed with exit code 1."])
  }
  lines.push([end - 10, "Cleaning up orphan processes"])
  job.log_text = lines.map(([ms, text]) => `${iso(ms)} ${text}`).join("\n") + "\n"
}

route("GET", /^\/repos\/([^/]+)\/([^/]+)\/actions\/jobs\/(\d+)\/logs$/, (req, res, url, [, o, r, id]) => {
  const job = state.jobs.find(j => j.id === Number(id))
  if (!job || !job.log_text) return send(res, 404, { message: "Not Found" })
  res.writeHead(302, { location: `${self}/__fake/blobs/${job.id}?sig=${randomBytes(8).toString("hex")}` })
  res.end()
})

route("GET", /^\/__fake\/blobs\/(\d+)$/, (req, res, url, [, id]) => {
  const job = state.jobs.find(j => j.id === Number(id))
  if (!job || !job.log_text) return send(res, 404, { message: "Not Found" })
  if (req.headers.authorization) return send(res, 400, { message: "the blob host got a token" })
  res.writeHead(200, { "content-type": "text/plain" })
  res.end(job.log_text)
})

// -- webhook deliveries ----------------------------------------------------------------

async function deliver(event, payload, { guid = randomUUID(), redelivery = false } = {}) {
  const a = app()
  if (!a) return
  const body = JSON.stringify(payload)
  const signature = "sha256=" + createHmac("sha256", a.webhook_secret).update(body).digest("hex")
  const delivery = { id: id(), guid, event, action: payload.action, redelivery, delivered_at: new Date().toISOString(), payload, status_code: 0 }
  state.deliveries.unshift(delivery)
  if (state.dropNext > 0) {
    state.dropNext--
    delivery.status_code = 502
    return delivery
  }
  try {
    const resp = await fetch(crewHook, {
      method: "POST",
      headers: { "content-type": "application/json", "x-github-event": event, "x-github-delivery": guid, "x-hub-signature-256": signature },
      body,
    })
    delivery.status_code = resp.status
  } catch (e) {
    delivery.status_code = 503
  }
  return delivery
}

const withContext = (repo, payload) => ({
  ...payload,
  repository: repoJson(repo),
  installation: { id: repo.installation_id },
  sender: { login: state.user.login },
})

route("GET", /^\/app\/hook\/deliveries$/, (req, res) => {
  send(res, 200, state.deliveries.slice(0, 100).map(({ payload, ...d }) => d))
})
route("POST", /^\/app\/hook\/deliveries\/(\d+)\/attempts$/, async (req, res, url, [, did]) => {
  const d = state.deliveries.find(x => x.id === Number(did))
  if (!d) return send(res, 404, { message: "Not Found" })
  send(res, 202, {})
  deliver(d.event, d.payload, { guid: d.guid, redelivery: true })
})

// -- control ------------------------------------------------------------------------

// Adds repos to the (first) installation, and sends installation_repositories.
route("POST", /^\/__fake\/repos$/, async (req, res) => {
  const { names = [], private: priv = true } = await readBody(req)
  const installation = state.installations[0]
  if (!installation) return send(res, 400, { message: "no installation" })
  const added = names.map(name => {
    const repo = { id: id(), full_name: `${installation.account.login}/${name}`, private: priv, default_branch: "main", installation_id: installation.id }
    state.repos.push(repo)
    return repo
  })
  await deliver("installation_repositories", {
    action: "added",
    installation: { id: installation.id, account: installation.account },
    repositories_added: added.map(repoJson),
    repositories_removed: [],
  })
  send(res, 200, added.map(repoJson))
})

// Queues a run: workflow_run requested, then workflow_job queued for each job.
route("POST", /^\/__fake\/runs$/, async (req, res) => {
  const b = await readBody(req)
  const [o, r] = b.repo.split("/")
  const repo = repoByName(o, r)
  if (!repo) return send(res, 404, { message: `no repo ${b.repo}` })
  const now = new Date().toISOString()
  const run = {
    id: b.id || id(), run_attempt: b.run_attempt || 1, run_number: b.run_number || state.runs.length + 1,
    repo_id: repo.id, name: b.workflow || "CI", event: b.event || "push", status: "queued", conclusion: null,
    head_branch: b.branch || "main", head_sha: b.sha || randomBytes(20).toString("hex"), message: b.message || "Commit",
    head_repo: b.head_repo === undefined ? repo.full_name : b.head_repo, pull_requests: b.pr ? [{ number: b.pr, head: { ref: b.branch }, base: { ref: "main" } }] : [],
    created_at: now, updated_at: now,
  }
  state.runs.push(run)
  if (!b.skipRunWebhook) await deliver("workflow_run", withContext(repo, { action: "requested", workflow_run: runJson(run) }))
  const jobs = (b.jobs || []).map(j => {
    const job = {
      id: id(), run_id: run.id, run_attempt: run.run_attempt, name: j.name, workflow_name: run.name, labels: j.labels,
      status: "queued", conclusion: null, created_at: now, started_at: now, completed_at: null, runner_name: null,
      runner_id: null, head_branch: run.head_branch, head_sha: run.head_sha,
      seconds: j.seconds, exit: j.exit, hold: j.hold || false, log: j.log, log_lines: j.log_lines,
    }
    state.jobs.push(job)
    return job
  })
  for (const job of jobs) await deliver("workflow_job", withContext(repo, { action: "queued", workflow_job: jobJson(job) }))
  send(res, 200, { run: runJson(run), jobs: jobs.map(jobJson) })
})

// Moves a job along (in_progress, completed) and sends its webhook.
route("POST", /^\/__fake\/jobs\/(\d+)$/, async (req, res, url, [, jid]) => {
  const b = await readBody(req)
  const job = state.jobs.find(j => j.id === Number(jid))
  if (!job) return send(res, 404, { message: "no job" })
  send(res, 200, jobJson(await moveJob(job, b)))
})

async function moveJob(job, b) {
  Object.assign(job, b)
  if (b.status === "in_progress") job.started_at = new Date().toISOString()
  if (b.status === "completed") job.completed_at = new Date().toISOString()
  const run = state.runs.find(x => x.id === job.run_id && x.run_attempt === job.run_attempt)
  const repo = state.repos.find(r => r.id === run.repo_id)
  const runJobs = state.jobs.filter(j => j.run_id === run.id && j.run_attempt === run.run_attempt)
  if (runJobs.every(j => j.status === "completed")) {
    run.status = "completed"
    run.conclusion = runJobs.every(j => ["success", "skipped"].includes(j.conclusion)) ? "success" : "failure"
  } else if (runJobs.some(j => j.status === "in_progress")) run.status = "in_progress"
  run.updated_at = new Date().toISOString()
  await deliver("workflow_job", withContext(repo, { action: job.status, workflow_job: jobJson(job) }))
  if (["in_progress", "completed"].includes(run.status)) await deliver("workflow_run", withContext(repo, { action: run.status, workflow_run: runJson(run) }))
  return job
}

route("POST", /^\/__fake\/drop$/, async (req, res) => {
  state.dropNext = (await readBody(req)).count || 1
  send(res, 200, { dropNext: state.dropNext })
})

route("POST", /^\/__fake\/ping$/, async (req, res) => {
  const d = await deliver("ping", { zen: "Design for failure.", hook_id: 1, hook: { type: "App" } })
  send(res, 200, { status_code: d?.status_code })
})


route("POST", /^\/__fake\/releases$/, async (req, res) => {
  state.crewReleases = await readBody(req)
  send(res, 200, {ok: true})
})
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
