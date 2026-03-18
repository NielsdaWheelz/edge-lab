import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";

const port = Number(process.env.PORT ?? "9090");
const expectedRuntimeId = process.env.EDGE_EXPECTED_RUNTIME_ID ?? "runtime-abc";
const expectedCredential = process.env.EDGE_EXPECTED_CREDENTIAL ?? "cred-good";
const expectedGeneration = process.env.EDGE_EXPECTED_GENERATION ?? "gen-2";
const expectedSubdomain = process.env.EDGE_EXPECTED_SUBDOMAIN ?? "preview-abc";
const expectedFullHost = process.env.EDGE_EXPECTED_FULL_HOST ?? "preview-abc.codapt.local";
const phase1Host = process.env.EDGE_PHASE1_HOST ?? "preview-abc.codapt.local";
const phase1Subdomain = process.env.EDGE_PHASE1_SUBDOMAIN ?? "preview-abc";
const phase1Generation2PublicId = process.env.EDGE_PHASE1_GENERATION_2_PUBLIC_ID ?? "gpub2";
const phase1Generation2LeaseToken = process.env.EDGE_PHASE1_GENERATION_2_LEASE_TOKEN ?? "lease-gen2-good";
const phase1Generation3PublicId = process.env.EDGE_PHASE1_GENERATION_3_PUBLIC_ID ?? "gpub3";
const phase1Generation3LeaseToken = process.env.EDGE_PHASE1_GENERATION_3_LEASE_TOKEN ?? "lease-gen3-good";
const phase1ProbeUrl = process.env.EDGE_PHASE1_PROBE_URL ?? "http://frps:8080/health";
const artifactsDir = process.env.ARTIFACTS_DIR ?? "/artifacts";
const caddyApiUrl = (process.env.CADDY_API_URL ?? "").replace(/\/+$/, "");

const routeState = new Map();
let phase1Generations = createPhase1GenerationDefinitions();
let phase1State = createPhase1State();
let phase1PersistTail = Promise.resolve();

function nowIso() {
	return new Date().toISOString();
}

function sendJson(res, status, payload) {
	res.writeHead(status, { "content-type": "application/json; charset=utf-8" });
	res.end(JSON.stringify(payload));
}

function sendText(res, status, payload) {
	res.writeHead(status, { "content-type": "text/plain; charset=utf-8" });
	res.end(payload);
}

function asObject(value) {
	return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function asString(value) {
	return typeof value === "string" && value.length > 0 ? value : null;
}

function headerValue(value) {
	if (typeof value === "string") {
		return value;
	}
	if (Array.isArray(value)) {
		return value.find((item) => typeof item === "string") ?? null;
	}
	return null;
}

function discoverOp(payload) {
	const p = asObject(payload);
	const content = asObject(p.content);
	return p.op ?? p.operation ?? content.op ?? content.operation ?? "unknown";
}

function extractMetadata(op, payload) {
	const content = asObject(payload.content);
	if (op === "Login") {
		return asObject(content.metas);
	}
	if (op === "NewProxy" || op === "Ping" || op === "CloseProxy") {
		return asObject(asObject(content.user).metas);
	}
	return {};
}

function extractSessionKey(op, payload) {
	if (op !== "NewProxy" && op !== "Ping" && op !== "CloseProxy") {
		return null;
	}
	return asString(asObject(asObject(payload.content).user).run_id);
}

function extractLoginRunId(payload) {
	return asString(asObject(payload.content).run_id);
}

function extractPrivilegeKey(payload) {
	return asString(asObject(payload.content).privilege_key);
}

function extractProxyName(payload) {
	return asString(asObject(payload.content).proxy_name);
}

function readBody(req) {
	return new Promise((resolve, reject) => {
		let raw = "";
		req.setEncoding("utf8");
		req.on("data", (chunk) => {
			raw += chunk;
			if (raw.length > 1024 * 1024) {
				reject(new Error("payload too large"));
				req.destroy();
			}
		});
		req.on("end", () => resolve(raw));
		req.on("error", reject);
	});
}

function expectedHostForSubdomain(subdomain) {
	return `${subdomain}.codapt.local`;
}

function phase1AliasSubdomain(generationPublicId) {
	return `g-${generationPublicId}-${phase1Subdomain}`;
}

function phase1AliasHost(generationPublicId) {
	return `${phase1AliasSubdomain(generationPublicId)}.codapt.local`;
}

function phase1ProxyName(generationPublicId) {
	return `g_${generationPublicId}__app`;
}

function createPhase1GenerationDefinitions() {
	return new Map([
		[
			phase1Generation2PublicId,
			{
				generationPublicId: phase1Generation2PublicId,
				leaseToken: phase1Generation2LeaseToken,
				internalSubdomain: phase1AliasSubdomain(phase1Generation2PublicId),
				internalHost: phase1AliasHost(phase1Generation2PublicId),
				proxyName: phase1ProxyName(phase1Generation2PublicId),
				revokedAt: null,
			},
		],
		[
			phase1Generation3PublicId,
			{
				generationPublicId: phase1Generation3PublicId,
				leaseToken: phase1Generation3LeaseToken,
				internalSubdomain: phase1AliasSubdomain(phase1Generation3PublicId),
				internalHost: phase1AliasHost(phase1Generation3PublicId),
				proxyName: phase1ProxyName(phase1Generation3PublicId),
				revokedAt: null,
			},
		],
	]);
}

function createPhase1State() {
	return {
		host: phase1Host,
		desiredGenerationPublicId: null,
		desiredAt: null,
		liveGenerationPublicId: null,
		publishedAt: null,
		drainingGenerationPublicId: null,
		drainingAt: null,
		sessions: new Map(),
	};
}

function normalizeRouteEntry(value) {
	if (typeof value === "string") {
		return { state: value, upstreamHost: null };
	}
	const entry = asObject(value);
	return {
		state: asString(entry.state) ?? "missing",
		upstreamHost: asString(entry.upstreamHost),
	};
}

function serializeRouteState() {
	const out = {};
	for (const [host, value] of routeState.entries()) {
		out[host] = normalizeRouteEntry(value);
	}
	return out;
}

function serializePhase1State() {
	return {
		host: phase1State.host,
		desiredGenerationPublicId: phase1State.desiredGenerationPublicId,
		desiredAt: phase1State.desiredAt,
		liveGenerationPublicId: phase1State.liveGenerationPublicId,
		publishedAt: phase1State.publishedAt,
		drainingGenerationPublicId: phase1State.drainingGenerationPublicId,
		drainingAt: phase1State.drainingAt,
		generations: [...phase1Generations.values()].map((value) => ({ ...value })),
		sessions: [...phase1State.sessions.values()].map((value) => ({ ...value })),
		routes: serializeRouteState(),
	};
}

async function ensureArtifactsDir() {
	await fs.mkdir(artifactsDir, { recursive: true });
}

async function appendArtifact(fileName, payload) {
	await ensureArtifactsDir();
	await fs.appendFile(path.join(artifactsDir, fileName), `${JSON.stringify(payload)}\n`, "utf8");
}

async function writeArtifactOnce(fileName, payload) {
	await ensureArtifactsDir();
	const outPath = path.join(artifactsDir, fileName);
	try {
		await fs.access(outPath);
	} catch {
		await fs.writeFile(outPath, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
	}
}

async function writeArtifact(fileName, payload) {
	await ensureArtifactsDir();
	await fs.writeFile(path.join(artifactsDir, fileName), `${JSON.stringify(payload, null, 2)}\n`, "utf8");
}

async function persistPhase1State() {
	phase1PersistTail = phase1PersistTail
		.catch(() => {})
		.then(() => writeArtifact("phase1-state.json", serializePhase1State()));
	await phase1PersistTail;
}

function renderCaddyfileFromState() {
	const lines = ["{", "    admin 0.0.0.0:2019", "}", ""];
	const entries = [...routeState.entries()].sort(([a], [b]) => a.localeCompare(b));

	for (const [host, rawState] of entries) {
		const state = normalizeRouteEntry(rawState);
		lines.push(`${host} {`);
		lines.push("    tls internal");
		if (state.state === "starting") {
			lines.push(`    respond "codapt-edge state=starting host=${host}" 200`);
		} else if (state.state === "live" && state.upstreamHost) {
			lines.push("    reverse_proxy frps:8080 {");
			lines.push(`        header_up Host ${state.upstreamHost}`);
			lines.push("    }");
		} else if (state.state === "live") {
			lines.push("    reverse_proxy frps:8080");
		} else {
			lines.push('    respond "route not found" 404');
		}
		lines.push("}");
		lines.push("");
	}

	lines.push("*.codapt.local {");
	lines.push("    tls internal");
	lines.push('    respond "route not found" 404');
	lines.push("}");
	lines.push("");
	return lines.join("\n");
}

async function pushRouteStateToCaddy(source) {
	if (!caddyApiUrl) {
		return { skipped: true, reason: "CADDY_API_URL not configured" };
	}

	const caddyfile = renderCaddyfileFromState();
	const adaptResponse = await fetch(`${caddyApiUrl}/adapt`, {
		method: "POST",
		headers: {
			"content-type": "text/caddyfile",
		},
		body: caddyfile,
	});

	const adaptRaw = await adaptResponse.text();
	if (!adaptResponse.ok) {
		throw new Error(`caddy adapt failed (${adaptResponse.status}): ${adaptRaw}`);
	}

	let adaptBody;
	try {
		adaptBody = JSON.parse(adaptRaw);
	} catch (error) {
		throw new Error(`failed to parse caddy adapt response: ${error.message}`);
	}

	const config = adaptBody.result ?? adaptBody;
	const loadResponse = await fetch(`${caddyApiUrl}/load`, {
		method: "POST",
		headers: {
			"content-type": "application/json",
		},
		body: JSON.stringify(config),
	});
	const loadRaw = await loadResponse.text();
	if (!loadResponse.ok) {
		throw new Error(`caddy load failed (${loadResponse.status}): ${loadRaw}`);
	}

	await appendArtifact("route-events.ndjson", {
		ts: nowIso(),
		event: "route-state-pushed",
		source,
		states: serializeRouteState(),
	});
	await fs.writeFile(path.join(artifactsDir, "caddy-active.caddyfile"), `${caddyfile}\n`, "utf8");
	await writeArtifact("route-state.json", serializeRouteState());
	return { ok: true };
}

function validateRouteBody(body) {
	const host = body.host;
	if (typeof host !== "string" || host.length === 0) {
		throw new Error("host is required");
	}
	return { host };
}

function validatePhase1PublishBody(body) {
	const host = typeof body.host === "string" && body.host.length > 0 ? body.host : phase1Host;
	const generationPublicId = body.generation_public_id ?? body.generationPublicId;
	if (host !== phase1Host) {
		throw new Error(`host mismatch: expected ${phase1Host}, got ${host}`);
	}
	if (typeof generationPublicId !== "string" || generationPublicId.length === 0) {
		throw new Error("generation_public_id is required");
	}
	return { host, generationPublicId };
}

function evaluateLegacyAuth(payload) {
	const op = discoverOp(payload);
	const content = asObject(payload.content);
	const metadata = extractMetadata(op, payload);
	const runtimeId = metadata.runtime_id ?? metadata.runtimeId;
	const credential = metadata.credential;
	const generation = metadata.generation;
	const subdomain = asString(content.subdomain);
	const fullHost = subdomain ? expectedHostForSubdomain(subdomain) : null;

	const reasons = [];
	if (runtimeId !== expectedRuntimeId) {
		reasons.push(`runtime_id mismatch: expected ${expectedRuntimeId}, got ${runtimeId ?? "missing"}`);
	}
	if (credential !== expectedCredential) {
		reasons.push("credential mismatch");
	}
	if (generation !== expectedGeneration) {
		reasons.push(`generation mismatch: expected ${expectedGeneration}, got ${generation ?? "missing"}`);
	}
	if (op === "NewProxy") {
		if (subdomain !== expectedSubdomain) {
			reasons.push(`subdomain mismatch: expected ${expectedSubdomain}, got ${subdomain ?? "missing"}`);
		}
		if (fullHost !== expectedFullHost) {
			reasons.push(`hostname mismatch: expected ${expectedFullHost}, got ${fullHost ?? "missing"}`);
		}
	}

	return {
		model: "legacy",
		op,
		runtimeId,
		credentialProvided: Boolean(credential),
		generation,
		subdomain,
		fullHost,
		reasons,
		reject: reasons.length > 0,
		metadata,
	};
}

function evaluatePhase1Auth(payload, req) {
	const op = discoverOp(payload);
	const content = asObject(payload.content);
	const metadata = extractMetadata(op, payload);
	const generationPublicId = asString(metadata.generation_public_id ?? metadata.generationPublicId);
	const leaseToken = asString(metadata.lease_token ?? metadata.leaseToken);
	const generation = generationPublicId ? phase1Generations.get(generationPublicId) ?? null : null;
	const subdomain = asString(content.subdomain);
	const fullHost = subdomain ? expectedHostForSubdomain(subdomain) : null;
	const proxyName = extractProxyName(payload);
	const sessionKey = extractSessionKey(op, payload);
	const loginRunId = op === "Login" ? extractLoginRunId(payload) : null;
	const privilegeKey = extractPrivilegeKey(payload);
	const reqId = headerValue(req.headers["x-frp-reqid"]);

	const reasons = [];
	if (!generationPublicId) {
		reasons.push("generation_public_id missing");
	}
	if (!leaseToken) {
		reasons.push("lease_token missing");
	}
	if (!generation) {
		reasons.push(`unknown generation_public_id: ${generationPublicId ?? "missing"}`);
	} else {
		if (leaseToken !== generation.leaseToken) {
			reasons.push("lease token mismatch");
		}
		if (generation.revokedAt && op !== "CloseProxy") {
			reasons.push("lease token revoked");
		}
	}

	if (op === "NewProxy") {
		if (!generation) {
			reasons.push("generation definition missing for proxy validation");
		} else {
			if (subdomain !== generation.internalSubdomain) {
				reasons.push(
					`subdomain mismatch: expected ${generation.internalSubdomain}, got ${subdomain ?? "missing"}`,
				);
			}
			if (fullHost !== generation.internalHost) {
				reasons.push(`hostname mismatch: expected ${generation.internalHost}, got ${fullHost ?? "missing"}`);
			}
			if (proxyName !== generation.proxyName) {
				reasons.push(`proxy_name mismatch: expected ${generation.proxyName}, got ${proxyName ?? "missing"}`);
			}
		}
	}

	if ((op === "NewProxy" || op === "Ping" || op === "CloseProxy") && !sessionKey) {
		reasons.push(`run_id missing on ${op}`);
	}

	return {
		model: "phase1",
		op,
		generationPublicId,
		leaseTokenProvided: Boolean(leaseToken),
		subdomain,
		fullHost,
		publicHost: phase1Host,
		aliasHost: generation?.internalHost ?? null,
		proxyName,
		sessionKey,
		loginRunId,
		privilegeKey,
		reqId,
		reasons,
		reject: reasons.length > 0,
		metadata,
	};
}

function evaluateAuth(payload, req) {
	const op = discoverOp(payload);
	const metadata = extractMetadata(op, payload);
	const isPhase1 =
		Object.prototype.hasOwnProperty.call(metadata, "generation_public_id") ||
		Object.prototype.hasOwnProperty.call(metadata, "generationPublicId") ||
		Object.prototype.hasOwnProperty.call(metadata, "lease_token") ||
		Object.prototype.hasOwnProperty.call(metadata, "leaseToken");

	return isPhase1 ? evaluatePhase1Auth(payload, req) : evaluateLegacyAuth(payload);
}

function upsertPhase1Session(authResult, ts) {
	if (!authResult.sessionKey || !authResult.generationPublicId) {
		return;
	}

	const existing = phase1State.sessions.get(authResult.sessionKey) ?? {
		sessionKey: authResult.sessionKey,
		generationPublicId: authResult.generationPublicId,
		proxyName: authResult.proxyName ?? null,
		connectedAt: null,
		verifiedAt: null,
		lastSeenAt: null,
		disconnectedAt: null,
		lastPrivilegeKey: null,
	};

	existing.generationPublicId = authResult.generationPublicId;
	existing.proxyName = authResult.proxyName ?? existing.proxyName;
	existing.lastPrivilegeKey = authResult.privilegeKey ?? existing.lastPrivilegeKey;

	if (authResult.op === "NewProxy") {
		existing.connectedAt ??= ts;
		existing.verifiedAt ??= ts;
		existing.lastSeenAt = ts;
		existing.disconnectedAt = null;
	}
	if (authResult.op === "Ping") {
		existing.connectedAt ??= ts;
		existing.lastSeenAt = ts;
		existing.disconnectedAt = null;
	}
	if (authResult.op === "CloseProxy") {
		existing.lastSeenAt = ts;
		existing.disconnectedAt = ts;
	}

	phase1State.sessions.set(authResult.sessionKey, existing);
}

async function observePhase1Auth(authResult, ts) {
	if (authResult.reject) {
		return;
	}
	if (authResult.op === "NewProxy" || authResult.op === "Ping" || authResult.op === "CloseProxy") {
		upsertPhase1Session(authResult, ts);
		await persistPhase1State();
	}
}

function findActiveVerifiedPhase1Session(generationPublicId) {
	for (const session of phase1State.sessions.values()) {
		if (session.generationPublicId !== generationPublicId) {
			continue;
		}
		if (!session.verifiedAt || session.disconnectedAt) {
			continue;
		}
		return session;
	}
	return null;
}

function phase1Probe(generationPublicId) {
	return new Promise((resolve) => {
		const generation = phase1Generations.get(generationPublicId) ?? null;
		if (!generation) {
			resolve({
				ts: nowIso(),
				ok: false,
				error: `unknown generation_public_id: ${generationPublicId}`,
			});
			return;
		}

		const probeUrl = new URL(phase1ProbeUrl);
		const request = http.request(
			{
				hostname: probeUrl.hostname,
				port: probeUrl.port ? Number(probeUrl.port) : 80,
				path: `${probeUrl.pathname}${probeUrl.search}`,
				method: "GET",
				headers: {
					Host: generation.internalHost,
				},
			},
			(res) => {
				let body = "";
				res.setEncoding("utf8");
				res.on("data", (chunk) => {
					body += chunk;
				});
				res.on("end", async () => {
					const result = {
						ts: nowIso(),
						generationPublicId,
						aliasHost: generation.internalHost,
						statusCode: res.statusCode ?? 0,
						body,
						ok: res.statusCode === 200 && body.includes("ok"),
					};
					await writeArtifact("phase1-probe.json", result);
					resolve(result);
				});
			},
		);

		request.on("error", async (error) => {
			const result = {
				ts: nowIso(),
				generationPublicId,
				aliasHost: generation.internalHost,
				statusCode: 0,
				error: error.message,
				ok: false,
			};
			await writeArtifact("phase1-probe.json", result);
			resolve(result);
		});

		request.end();
	});
}

async function resetPhase1() {
	phase1Generations = createPhase1GenerationDefinitions();
	phase1State = createPhase1State();
	routeState.delete(phase1Host);
	await pushRouteStateToCaddy("phase1-reset");
	await persistPhase1State();
	return serializePhase1State();
}

async function requestPublishPhase1(generationPublicId) {
	const generation = phase1Generations.get(generationPublicId) ?? null;
	if (!generation) {
		throw new Error(`unknown generation_public_id: ${generationPublicId}`);
	}

	phase1State.desiredGenerationPublicId = generationPublicId;
	phase1State.desiredAt = nowIso();

	if (!phase1State.liveGenerationPublicId) {
		routeState.set(phase1Host, { state: "starting", upstreamHost: null });
		await pushRouteStateToCaddy("phase1-request-publish");
	}

	await persistPhase1State();
	return serializePhase1State();
}

async function reconcilePhase1() {
	const desiredGenerationPublicId = phase1State.desiredGenerationPublicId;
	if (!desiredGenerationPublicId) {
		if (!phase1State.liveGenerationPublicId) {
			routeState.delete(phase1Host);
			await pushRouteStateToCaddy("phase1-reconcile-no-desired");
		}
		await persistPhase1State();
		return { ok: false, reason: "no desired generation", phase1: serializePhase1State() };
	}

	const activeSession = findActiveVerifiedPhase1Session(desiredGenerationPublicId);
	if (!activeSession) {
		if (!phase1State.liveGenerationPublicId) {
			routeState.set(phase1Host, { state: "starting", upstreamHost: null });
			await pushRouteStateToCaddy("phase1-reconcile-no-session");
		}
		await persistPhase1State();
		return { ok: false, reason: "no active verified session", phase1: serializePhase1State() };
	}

	const probe = await phase1Probe(desiredGenerationPublicId);
	if (!probe.ok) {
		if (!phase1State.liveGenerationPublicId) {
			routeState.set(phase1Host, { state: "starting", upstreamHost: null });
			await pushRouteStateToCaddy("phase1-reconcile-probe-failed");
		}
		await persistPhase1State();
		return { ok: false, reason: "probe failed", probe, phase1: serializePhase1State() };
	}

	const previousLiveGenerationPublicId = phase1State.liveGenerationPublicId;
	if (previousLiveGenerationPublicId && previousLiveGenerationPublicId !== desiredGenerationPublicId) {
		const previousGeneration = phase1Generations.get(previousLiveGenerationPublicId) ?? null;
		if (previousGeneration && !previousGeneration.revokedAt) {
			previousGeneration.revokedAt = nowIso();
		}
		phase1State.drainingGenerationPublicId = previousLiveGenerationPublicId;
		phase1State.drainingAt = nowIso();
	}

	phase1State.liveGenerationPublicId = desiredGenerationPublicId;
	phase1State.publishedAt = nowIso();
	routeState.set(phase1Host, {
		state: "live",
		upstreamHost: phase1AliasHost(desiredGenerationPublicId),
	});
	await pushRouteStateToCaddy("phase1-reconcile-live");
	await persistPhase1State();
	return { ok: true, probe, phase1: serializePhase1State() };
}

const server = http.createServer(async (req, res) => {
	const url = new URL(req.url ?? "/", "http://localhost");

	if (req.method === "GET" && url.pathname === "/health") {
		sendText(res, 200, "ok\n");
		return;
	}

	if (req.method === "GET" && url.pathname === "/route/state") {
		sendJson(res, 200, { routes: serializeRouteState() });
		return;
	}

	if (req.method === "GET" && url.pathname === "/phase1/state") {
		sendJson(res, 200, serializePhase1State());
		return;
	}

	if (req.method === "POST" && url.pathname === "/phase1/reset") {
		try {
			const state = await resetPhase1();
			sendJson(res, 200, { ok: true, phase1: state });
		} catch (error) {
			sendJson(res, 500, { error: error.message });
		}
		return;
	}

	if (req.method === "POST" && url.pathname === "/phase1/request-publish") {
		let body;
		try {
			const raw = await readBody(req);
			body = raw.length > 0 ? JSON.parse(raw) : {};
		} catch (error) {
			sendJson(res, 400, { error: `invalid payload: ${error.message}` });
			return;
		}

		try {
			const { generationPublicId } = validatePhase1PublishBody(body);
			const state = await requestPublishPhase1(generationPublicId);
			sendJson(res, 200, { ok: true, phase1: state });
			return;
		} catch (error) {
			sendJson(res, 400, { error: error.message });
			return;
		}
	}

	if (req.method === "POST" && url.pathname === "/phase1/reconcile") {
		try {
			const result = await reconcilePhase1();
			sendJson(res, 200, result);
			return;
		} catch (error) {
			sendJson(res, 500, { error: error.message });
			return;
		}
	}

	if (req.method === "POST" && url.pathname === "/frp-auth") {
		let payload;
		try {
			const raw = await readBody(req);
			payload = raw.length > 0 ? JSON.parse(raw) : {};
		} catch (error) {
			sendJson(res, 400, { reject: true, reject_reason: `invalid payload: ${error.message}` });
			return;
		}

		const ts = nowIso();
		const authResult = evaluateAuth(payload, req);
		const response = authResult.reject
			? { reject: true, reject_reason: authResult.reasons.join("; ") }
			: { reject: false, unchange: true };

		const eventPayload = {
			ts,
			event: "frp-auth",
			...authResult,
		};
		delete eventPayload.metadata;

		await appendArtifact("frp-auth-events.ndjson", eventPayload);
		if (authResult.op === "Login") {
			await writeArtifactOnce("plugin-login.json", payload);
		}
		if (authResult.op === "NewProxy") {
			await writeArtifactOnce("plugin-newproxy.json", payload);
		}
		if (authResult.op === "Ping") {
			await writeArtifactOnce("plugin-ping.json", payload);
		}
		if (authResult.op === "CloseProxy") {
			await writeArtifactOnce("plugin-closeproxy.json", payload);
		}

		if (authResult.model === "phase1") {
			await observePhase1Auth(authResult, ts);
		}

		console.log(
			JSON.stringify({
				event: "frp-auth",
				model: authResult.model,
				op: authResult.op,
				reject: authResult.reject,
				reasons: authResult.reasons,
				generationPublicId: authResult.generationPublicId ?? null,
				sessionKey: authResult.sessionKey ?? null,
				subdomain: authResult.subdomain ?? null,
			}),
		);

		sendJson(res, 200, response);
		return;
	}

	if (req.method === "POST" && url.pathname.startsWith("/route/")) {
		let body;
		try {
			const raw = await readBody(req);
			body = raw.length > 0 ? JSON.parse(raw) : {};
		} catch (error) {
			sendJson(res, 400, { error: `invalid payload: ${error.message}` });
			return;
		}

		try {
			if (url.pathname === "/route/reload") {
				const pushResult = await pushRouteStateToCaddy("manual-reload");
				sendJson(res, 200, { ok: true, pushResult, routes: serializeRouteState() });
				return;
			}

			const { host } = validateRouteBody(body);
			if (url.pathname === "/route/register-starting") {
				routeState.set(host, { state: "starting", upstreamHost: null });
			} else if (url.pathname === "/route/promote-live") {
				routeState.set(host, { state: "live", upstreamHost: null });
			} else if (url.pathname === "/route/remove") {
				routeState.delete(host);
			} else {
				sendJson(res, 404, { error: "not found" });
				return;
			}

			const pushResult = await pushRouteStateToCaddy(url.pathname);
			sendJson(res, 200, { ok: true, pushResult, routes: serializeRouteState() });
			return;
		} catch (error) {
			sendJson(res, 500, { error: error.message });
			return;
		}
	}

	if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/starting" || url.pathname === "/unavailable")) {
		const state = url.pathname === "/" ? "starting" : url.pathname.slice(1);
		sendText(
			res,
			200,
			`codapt-edge-stub state=${state} host=${req.headers.host ?? "unknown"} ts=${nowIso()}\n`,
		);
		return;
	}

	sendText(res, 404, "not found\n");
});

server.listen(port, async () => {
	await ensureArtifactsDir();
	await writeArtifact("route-state.json", serializeRouteState());
	await persistPhase1State();
	console.log(`codapt-edge-stub listening on :${port}`);
});
