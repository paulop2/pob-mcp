// pob-oracle implementation adapter: scores this server's Lua bridge against
// pob-oracle's golden outputs (https://github.com/paulop2/pob-oracle).
//
// Usage: node tools/oracle_impl.mjs <in.jsonl> <out.jsonl>
//   in:  {"id": "...", "xml": "<PathOfBuilding>..."} per line
//   out: {"id": "...", "ok": true, "output": {flat stats}} or {"id", "ok": false, "error"}
//
// The bridge is started the same way as the MCP server does it: POB_PATH,
// POB_CMD and POB_ARGS (see README), so the score reflects what the server runs.
import { createReadStream } from 'node:fs';
import { open } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { PoBLuaApiClient } from '../build/pobLuaBridge.js';

const [inPath, outPath] = process.argv.slice(2);
if (!inPath || !outPath) {
  console.error('usage: node tools/oracle_impl.mjs <in.jsonl> <out.jsonl>');
  process.exit(2);
}
const cwd = process.env.POB_PATH;
if (!cwd) throw new Error('POB_PATH must point to a PoB src directory.');
const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.env.POB_ARGS
  ? process.env.POB_ARGS.split(/\s+/).filter(Boolean)
  : [resolve(repo, 'lua/vanilla_stdio_bridge.lua')];

let client;
async function startClient() {
  client = new PoBLuaApiClient({ cwd, cmd: process.env.POB_CMD || 'luajit', args, timeoutMs: 600_000 });
  await client.start();
}

const out = await open(outPath, 'w');
await startClient();
try {
  const lines = createInterface({ input: createReadStream(inPath, 'utf8'), crlfDelay: Infinity });
  for await (const line of lines) {
    if (!line.trim()) continue;
    const req = JSON.parse(line);
    let record;
    try {
      if (req.ops) throw new Error('ops deltas are not supported by the MCP adapter');
      await client.loadBuildXml(req.xml, req.id);
      record = { id: req.id, ok: true, output: await client.getOutput() };
    } catch (err) {
      record = { id: req.id, ok: false, error: err instanceof Error ? err.message : String(err) };
      // A timeout kills the bridge; start a new one for the next request.
      if (/terminated|exited|not started/.test(record.error)) await startClient();
    }
    await out.write(JSON.stringify(record) + '\n');
  }
} finally {
  await out.close();
  await client.stop();
}
