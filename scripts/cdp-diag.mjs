// 诊断 home 页面加载状态
const port = 9333;

async function main() {
    const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    for (const t of targets.filter((x) => x.type === "page")) {
        const ws = new WebSocket(t.webSocketDebuggerUrl);
        await new Promise((r, j) => {
            ws.onopen = r;
            ws.onerror = j;
        });
        let id = 1;
        const pending = new Map();
        ws.addEventListener("message", (ev) => {
            const m = JSON.parse(String(ev.data));
            if (m.id && pending.has(m.id)) {
                pending.get(m.id)(m);
                pending.delete(m.id);
            }
        });
        const call = (method, params) => new Promise((resolve) => {
            const mid = id++;
            pending.set(mid, resolve);
            ws.send(JSON.stringify({ id: mid, method, params }));
        });
        const evalOn = async (expr) => {
            const r = await call("Runtime.evaluate", { expression: expr, returnByValue: true });
            if (r.exceptionDetails) {
                return "EXC: " + JSON.stringify(r.exceptionDetails).slice(0, 150);
            }
            return r.result?.value;
        };
        const label = await evalOn("window.__TAURI_INTERNALS__?.metadata?.currentWindow?.label");
        console.log("label =", label);
        if (label === "home") {
            const info = await evalOn(
                '[document.readyState, location.href, document.getElementById("root")?.childElementCount, document.querySelectorAll("*").length, typeof window.__TAURI_INTERNALS__].join(" ~ ")'
            );
            console.log("HOME:", info);
        }
        ws.close();
    }
}

main().catch((e) => {
    console.error("ERR", e.message);
    process.exit(1);
});