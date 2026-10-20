import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Vite 构建配置：仅面向 Tauri 2 内嵌 WebView2，开发服务器端口与 tauri.conf.json 的 devUrl 对应
export default defineConfig({
    plugins: [react()],
    // 阻止 Vite 清屏，保留 Rust 编译错误输出
    clearScreen: false,
    server: {

        port: 5173,
        strictPort: true
    },
    build: {
        // WebView2 (Chromium) 目标环境
        target: "chrome120",
        outDir: "dist"
    }
});