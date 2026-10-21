// 直接调用 open_home 命令验证 Rust 侧响应
const port = 9333;

async function main() {
    const { execSync } = await import("node:child_process");
    const runSelftest = (action) =>
        String(execSync(`powershell -NoProfile -ExecutionPolicy Bypass -File scripts/selftest.ps1 ${action} home`, { stdio: ["pipe", "pipe", "pipe"] }).toString()).trim();

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
            const r = await call("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true });
            if (r.exceptionDetails) {
                return "EXC: " + JSON.stringify(r.exceptionDetails).slice(0, 200);
            }
            return r.result?.result?.value;
        };
        const label = await evalOn("window.__TAURI_INTERNALS__?.metadata?.currentWindow?.label");
        console.log("label =", label);
        if (label === "capsule") {
            console.log("capsule target found");
            const result = await evalOn(
                'window.__TAURI_INTERNALS__.invoke("open_home").then(() => "RESOLVED").catch((e) => "REJECTED: " + String(e))'
            );
            console.log("invoke open_home =>", result);
            await new Promise((r) => setTimeout(r, 1500));
            console.log("home visibility =>", runSelftest("isvis"));
        }
        ws.close();
    }
}

main().catch((e) => {
    console.error("ERR", e.message);
    process.exit(1);
});