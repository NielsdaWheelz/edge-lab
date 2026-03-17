import { WebSocket } from "ws";

const target = process.env.WS_TARGET_URL ?? "wss://caddy/ws";
const hostHeader = process.env.WS_HOST_HEADER ?? "preview-abc.codapt.local";
const expected = `echo-${Date.now()}`;
const timeoutMs = 8000;

const socket = new WebSocket(target, {
	rejectUnauthorized: false,
	servername: hostHeader,
	headers: { Host: hostHeader },
});

let done = false;

function fail(message) {
	if (done) {
		return;
	}
	done = true;
	console.error(message);
	process.exitCode = 1;
	try {
		socket.close();
	} catch (error) {
		// no-op
	}
}

const timeout = setTimeout(() => {
	fail(`timeout waiting for ws echo from ${target}`);
}, timeoutMs);

socket.on("open", () => {
	socket.send(expected);
});

socket.on("message", (payload, isBinary) => {
	if (done) {
		return;
	}
	const received = isBinary ? payload.toString("utf8") : payload.toString();
	if (received !== expected) {
		fail(`unexpected ws echo payload: expected=${expected} got=${received}`);
		return;
	}

	done = true;
	clearTimeout(timeout);
	console.log(`ws echo ok: ${received}`);
	socket.close();
});

socket.on("error", (error) => {
	fail(`ws error: ${error.message}`);
});

socket.on("close", () => {
	if (!done) {
		fail("ws closed before receiving echo");
	}
});
