// The few Node.js APIs the tests use (vitest runs on Node); declared here so
// the Worker's type check needs no @types/node, which would clash with
// @cloudflare/workers-types.

declare module "node:child_process" {
  export function execFileSync(
    file: string,
    args?: string[],
    options?: { stdio?: "ignore" | "pipe"; encoding?: "utf8"; env?: Record<string, string | undefined> },
  ): string;
}
declare module "node:fs" {
  export function mkdtempSync(prefix: string): string;
  export function rmSync(path: string, options?: { recursive?: boolean; force?: boolean }): void;
  export function writeFileSync(path: string, data: Uint8Array): void;
}
declare module "node:os" {
  export function tmpdir(): string;
}
declare module "node:path" {
  export function join(...parts: string[]): string;
}
declare module "node:zlib" {
  export function crc32(data: Uint8Array, value?: number): number;
}
declare const process: { env: Record<string, string | undefined> };
