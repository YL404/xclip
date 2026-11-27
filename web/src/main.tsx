import "./styles/index.css";
import { render } from "preact";
import { createMyGoClient } from "./api";
import { App } from "./App";

const root = document.getElementById("app");
if (root) {
  render(<App client={createMyGoClient()} />, root);
}
