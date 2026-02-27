import fs from "node:fs";
import os from "node:os";
import path from "node:path";

type LogLevel = "debug" | "info" | "warn" | "error";

const LOG_FILE = path.join(os.tmpdir(), "3d-viewer.log");

function shouldDebugLog(): boolean {
  try {
    if (process.env["VIEWER_DEBUG"] === "1") return true;
    if (window.location.search.includes("debug=1")) return true;
    if (window.localStorage.getItem("3d-viewer.debug") === "1") return true;
  } catch {
    // ignore
  }
  return false;
}

function shouldLog(level: LogLevel): boolean {
  if (level === "debug") return shouldDebugLog();
  return true;
}

function toLine(level: LogLevel, msg: string): string {
  return `[${new Date().toISOString()}] [${level}] ${msg}`;
}

function appendLogFile(line: string): void {
  try {
    fs.appendFileSync(LOG_FILE, `${line}\n`, { encoding: "utf8" });
  } catch {
    // ignore file logging failures
  }
}

export function log(level: LogLevel, message: string): void {
  if (!shouldLog(level)) return;
  const line = toLine(level, message);
  appendLogFile(line);
  console[level === "debug" ? "log" : level](`[3d-viewer] ${message}`);
}

export function logInfo(message: string): void {
  log("info", message);
}

export function logWarn(message: string): void {
  log("warn", message);
}

export function logError(message: string): void {
  log("error", message);
}

export function logDebug(message: string): void {
  log("debug", message);
}

export function getLogFilePath(): string {
  return LOG_FILE;
}
