import http from "node:http";
import os from "node:os";
import { WebSocketServer } from "ws";

const port = Number(process.env.PORT ?? "8000");
const appLabel = process.env.APP_LABEL ?? "default";

function sendText(res, status, payload) {
	res.writeHead(status, { "content-type": "text/plain; charset=utf-8" });
	res.end(payload);
}

function sendJson(res, status, payload) {
	res.writeHead(status, { "content-type": "application/json; charset=utf-8" });
	res.end(JSON.stringify(payload));
}

const server = http.createServer((req, res) => {
	const url = new URL(req.url ?? "/", "http://localhost");

	if (req.method === "GET" && url.pathname === "/") {
		sendText(res, 200, `label=${appLabel} hostname=${os.hostname()} timestamp=${new Date().toISOString()}\n`);
		return;
	}

	if (req.method === "GET" && url.pathname === "/health") {
		sendText(res, 200, "ok\n");
		return;
	}

	if (req.method === "GET" && url.pathname === "/sse") {
		res.writeHead(200, {
			"content-type": "text/event-stream; charset=utf-8",
			"cache-control": "no-cache, no-transform",
			connection: "keep-alive",
		});

		const emit = () => {
			const payload = JSON.stringify({
				label: appLabel,
				hostname: os.hostname(),
				timestamp: new Date().toISOString(),
			});
			res.write(`data: ${payload}\n\n`);
		};

		emit();
		const interval = setInterval(emit, 1000);

		req.on("close", () => {
			clearInterval(interval);
		});
		return;
	}

	if (req.method === "POST" && url.pathname === "/upload") {
		let bytes = 0;

		req.on("data", (chunk) => {
			bytes += chunk.length;
		});

		req.on("end", () => {
			sendJson(res, 200, { bytes });
		});

		req.on("error", (error) => {
			sendJson(res, 400, { error: error.message });
		});
		return;
	}

	sendText(res, 404, "not found\n");
});

const wss = new WebSocketServer({ noServer: true });

wss.on("connection", (ws) => {
	ws.on("message", (message, isBinary) => {
		ws.send(message, { binary: isBinary });
	});
});

server.on("upgrade", (request, socket, head) => {
	const url = new URL(request.url ?? "/", "http://localhost");
	if (url.pathname !== "/ws") {
		socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
		socket.destroy();
		return;
	}

	wss.handleUpgrade(request, socket, head, (ws) => {
		wss.emit("connection", ws, request);
	});
});

server.listen(port, () => {
	console.log(`demo-app listening on :${port}`);
});
