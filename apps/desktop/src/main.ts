import { mount } from "svelte";
import App from "./App.svelte";
import "./app.css";

// Sample data instead of the Rust side, only with `npm run mock`.
if (import.meta.env.MODE === "mock") await import("./dev/mock");

const target = document.getElementById("app");
if (!target) throw new Error("#app missing in index.html");

export default mount(App, { target });
