// The pi integration's hello (integrations/pi/lib/protocol.ts, HelloFlow) against a real control
// socket: src/socket_hello_test.odin runs it. Argv: socket path, env token. Prints one JSON line:
// the env token's hello, then a reconnect with the token it gave, and every line each sent.
import net from "node:net";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..");
const { HelloFlow, deskToken, parse, tokenHello } = await import(pathToFileURL(path.join(root, "integrations/pi/lib/protocol.ts")).href);
const [sock, env] = process.argv.slice(2);

function hello(token, id) {
	return new Promise((done) => {
		const s = net.createConnection(sock);
		const f = new HelloFlow("DECKHAND_TOKEN", id, token);
		const sent = [];
		let buf = "";
		let over = false;
		const end = (r) => {
			if (over) return;
			over = true;
			s.destroy();
			done({ ...r, sent });
		};
		s.setEncoding("utf8");
		s.on("connect", () => {
			sent.push(f.first);
			s.write(f.first);
		});
		s.on("data", (c) => {
			buf += c;
			let nl;
			while ((nl = buf.indexOf("\n")) >= 0) {
				const m = parse(buf.slice(0, nl));
				buf = buf.slice(nl + 1);
				const st = m && f.onLine(m);
				if (!st) continue;
				if ("send" in st) {
					sent.push(st.send);
					s.write(st.send);
				} else end("ok" in st ? { ok: true, data: st.ok.data } : { ok: false, error: st.fail });
			}
		});
		s.on("error", () => {});
		s.on("close", () => end({ ok: false, error: "closed" }));
	});
}

const first = await hello(env, "b1");
const kind = tokenHello("DECKHAND_TOKEN");
const re = deskToken();
const again = await hello(re, "b2");
console.log(JSON.stringify({ first_ok: first.ok, kind, again_ok: again.ok, again_error: again.error ?? "", tab_id: again.data?.tab_id ?? 0, leaked: again.sent.some((l) => l.includes(re)), lines: again.sent.length }));
