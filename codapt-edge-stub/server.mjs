import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";

const port = Number(process.env.PORT ?? "9090");
const expectedRuntimeId = process.env.EDGE_EXPECTED_RUNTIME_ID ?? "runtime-abc";
const expectedCredential = process.env.EDGE_EXPECTED_CREDENTIAL ?? "cred-good";
const expectedGeneration = process.env.EDGE_EXPECTED_GENERATION ?? "gen-2";
const expectedSubdomain = process.env.EDGE_EXPECTED_SUBDOMAIN ?? "preview-abc";
const expectedFullHost = process.env.EDGE_EXPECTED_FULL_HOST ?? "preview-abc.codapt.local";
const artifactsDir = process.env.ARTIFACTS_DIR ?? "/artifacts";
const caddyApiUrl = (process.env.CADDY_API_URL ?? "").replace(/\/+$/, "");

const routeState = new Map();

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
	if (op === "NewProxy") {
		return asObject(asObject(content.user).metas);
	}
	return {};
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

function renderCaddyfileFromState() {
	const lines = ["{", "    admin 0.0.0.0:2019", "}", ""];
	const entries = [...routeState.entries()].sort(([a], [b]) => a.localeCompare(b));

	for (const [host, state] of entries) {
		lines.push(`${host} {`);
		lines.push("    tls internal");
		if (state === "starting") {
			lines.push(`    respond "codapt-edge state=starting host=${host}" 200`);
		} else if (state === "live") {
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
		ts: new Date().toISOString(),
		event: "route-state-pushed",
		source,
		states: Object.fromEntries(routeState.entries()),
	});
	await fs.writeFile(path.join(artifactsDir, "caddy-active.caddyfile"), `${caddyfile}\n`, "utf8");
	await writeArtifact("route-state.json", Object.fromEntries(routeState.entries()));
	return { ok: true };
}

function validateRouteBody(body) {
	const host = body.host;
	if (typeof host !== "string" || host.length === 0) {
		throw new Error("host is required");
	}
	return { host };
}

function evaluateAuth(payload) {
	const op = discoverOp(payload);
	const content = asObject(payload.content);
	const metadata = extractMetadata(op, payload);
	const runtimeId = metadata.runtime_id ?? metadata.runtimeId;
	const credential = metadata.credential;
	const generation = metadata.generation;
	const subdomain = content.subdomain;
	const fullHost = typeof subdomain === "string" ? expectedHostForSubdomain(subdomain) : null;

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
		op,
		runtimeId,
		credentialProvided: Boolean(credential),
		generation,
		subdomain: typeof subdomain === "string" ? subdomain : null,
		fullHost,
		reasons,
		reject: reasons.length > 0,
		metadata,
	};
}

const server = http.createServer(async (req, res) => {
	const url = new URL(req.url ?? "/", "http://localhost");

	if (req.method === "GET" && url.pathname === "/health") {
		sendText(res, 200, "ok\n");
		return;
	}

	if (req.method === "GET" && url.pathname === "/route/state") {
		sendJson(res, 200, { routes: Object.fromEntries(routeState.entries()) });
		return;
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

		const authResult = evaluateAuth(payload);
		const response = authResult.reject
			? { reject: true, reject_reason: authResult.reasons.join("; ") }
			: { reject: false, unchange: true };

		const eventPayload = {
			ts: new Date().toISOString(),
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

		console.log(
			JSON.stringify({
				event: "frp-auth",
				op: authResult.op,
				reject: authResult.reject,
				reasons: authResult.reasons,
				subdomain: authResult.subdomain,
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
				sendJson(res, 200, { ok: true, pushResult, routes: Object.fromEntries(routeState.entries()) });
				return;
			}

			const { host } = validateRouteBody(body);
			if (url.pathname === "/route/register-starting") {
				routeState.set(host, "starting");
			} else if (url.pathname === "/route/promote-live") {
				routeState.set(host, "live");
			} else if (url.pathname === "/route/remove") {
				routeState.delete(host);
			} else {
				sendJson(res, 404, { error: "not found" });
				return;
			}

			const pushResult = await pushRouteStateToCaddy(url.pathname);
			sendJson(res, 200, { ok: true, pushResult, routes: Object.fromEntries(routeState.entries()) });
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
			`codapt-edge-stub state=${state} host=${req.headers.host ?? "unknown"} ts=${new Date().toISOString()}\n`,
		);
		return;
	}

	sendText(res, 404, "not found\n");
});

server.listen(port, async () => {
	await ensureArtifactsDir();
	await writeArtifact("route-state.json", {});
	console.log(`codapt-edge-stub listening on :${port}`);
});
