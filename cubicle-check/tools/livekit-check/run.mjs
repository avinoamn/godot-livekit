// Checks godot-livekit (the voice spike's clients, #147) against the local LiveKit (npm run livekit,
// or livekit-server with dev/livekit.yaml): mints tokens from the dev key and starts Godot clients
// (client.gd, through check.gd). .github/workflows/native.yml runs it on each new build. From the
// repo root:
//
// Echo test (speakers on, not headphones): run it twice and compare client 1's "echo" lines, how
// loud its tone comes back in client 0's mic:
//   node tools/livekit-check/run.mjs --clients=2 --mic=device --window --thread --video=0 --seconds=40
//   node tools/livekit-check/run.mjs --clients=2 --mic=device --window --thread --video=0 --seconds=40 --aec
//
//   node tools/livekit-check/run.mjs [--clients=2] [--publishers=0] [--mic=tone|device|off]
//        [--video=1] [--volume-db=0] [--seconds=20] [--window] [--release] [--url=ws://...]
//        [--leave-at=S [--rejoin] [--leaver=N]]
//
// --leave-at makes every client leave at S seconds (and rejoin 2 s later with --rejoin);
// with --leaver=N only client N leaves, and the others stay.
//
// Client 0 is the one measured (logs to build/livekit-check/c0.csv). --publishers=N adds one more
// process with N room connections, each publishing a tone and a face, standing in for N people.
// --seconds=0 runs until the clients are closed.
import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AccessToken } from 'livekit-server-sdk';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
if (existsSync(join(root, '.env'))) process.loadEnvFile(join(root, '.env'));
const godot = process.env.GODOT || 'godot';
const args = Object.fromEntries(
  process.argv
    .slice(2)
    .filter((a) => a.startsWith('--'))
    .map((a) => {
      const [k, v] = a.slice(2).split('=');
      return [k, v ?? '1'];
    }),
);

// The dev key pair from dev/livekit.yaml; never used anywhere else.
const KEY = 'devkey';
const SECRET = 'dev-only-livekit-secret-0123456789abcdef';
const ROOM = `check-${Date.now()}`; // a room per run, so nobody from the last one is still in it

async function token(identity) {
  const at = new AccessToken(KEY, SECRET, { identity, ttl: '1h' });
  at.addGrant({ roomJoin: true, room: ROOM, canPublish: true, canSubscribe: true });
  return at.toJwt();
}

const seconds = Number(args.seconds ?? 20);
const logDir = join(root, 'build', 'livekit-check');
mkdirSync(logDir, { recursive: true });
const common = [
  `--url=${args.url ?? 'ws://127.0.0.1:7880'}`,
  `--video=${args.video ?? 1}`,
  `--queue-ms=${args['queue-ms'] ?? 0}`,
  `--shutdown=${args.shutdown ?? 'disconnect'}`,
  ...(args.thread ? ['--thread=1'] : []),
  ...(seconds ? [`--quit-after=${seconds}`] : []),
];

function start(name, tokens, extra, windowed) {
  const godotArgs = [
    '--path',
    'game',
    ...(windowed ? [] : ['--headless']),
    '-s',
    join(here, 'check.gd'),
    '--',
    `--tokens=${tokens.join(',')}`,
    `--log=${join(logDir, `${name}.csv`)}`,
    ...common,
    ...extra,
  ];
  const child = spawn(godot, godotArgs, { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
  child.stdout.on('data', (d) => process.stdout.write(`[${name}] ${d}`));
  child.stderr.on('data', (d) => process.stdout.write(`[${name}] ${d}`));
  child.on('exit', (code) =>
    console.log(`${name} exited with ${code} (0x${(code >>> 0).toString(16)})`),
  );
  return child;
}

// A real mic needs Godot's audio input on, a project setting: set for this run only.
const override = join(root, 'game', 'override.cfg');
if (args.mic === 'device')
  writeFileSync(override, ['[audio]', '', 'driver/enable_input=true', ''].join('\n'));
process.on('exit', () => {
  if (args.mic === 'device') rmSync(override, { force: true });
});

const children = [];
const clients = Number(args.clients ?? 2);
for (let i = 0; i < clients; i++) {
  const mic = i === 0 ? (args.mic ?? 'tone') : 'tone';
  const extra = [
    `--mic=${mic}`,
    `--tone-hz=${330 + 110 * i}`,
    `--volume-db=${args['volume-db'] ?? 0}`,
  ];
  if (args['leave-at'] && (args.leaver === undefined || Number(args.leaver) === i)) {
    extra.push(`--leave-at=${args['leave-at']}`);
    if (args.rejoin) extra.push('--rejoin=1');
  }
  children.push(start(`c${i}`, [await token(`c${i}`)], extra, args.window && i === 0));
}
const publishers = Number(args.publishers ?? 0);
// Several room connections in one process connect slowly (some time out), so --per-process (1).
const perProcess = Number(args['per-process'] ?? 1);
for (let first = 0; first < publishers; first += perProcess) {
  const tokens = [];
  for (let i = first; i < Math.min(publishers, first + perProcess); i++)
    tokens.push(await token(`p${i}`));
  children.push(
    start(
      `publishers${first}`,
      tokens,
      ['--mic=tone', `--tone-hz=${550 + 50 * first}`, '--subscribe=0'],
      false,
    ),
  );
}
// Client 0's CPU (all its threads: decoding, encoding, audio), from Windows, between two samples.
// The console wrapper starts the real Godot as its child: both are counted.
function cpuSeconds() {
  const pid = children[0].pid;
  const script = `Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -eq ${pid} -or $_.ParentProcessId -eq ${pid} } | ForEach-Object { "$($_.Name) $($_.KernelModeTime + $_.UserModeTime)" }`;
  const out = execFileSync('powershell.exe', ['-NoProfile', '-Command', script], {
    encoding: 'utf8',
  });
  if (args.debug) console.log(out);
  return out
    .split(/\r?\n/)
    .filter((line) => line.startsWith('Godot'))
    .reduce((sum, line) => sum + Number(line.split(' ').at(-1)) / 1e7, 0);
}
if (process.platform === 'win32' && seconds > 10) {
  await new Promise((r) => setTimeout(r, 6000));
  const [a, t0] = [cpuSeconds(), Date.now()];
  await new Promise((r) => setTimeout(r, (seconds - 9) * 1000));
  const used = cpuSeconds() - a;
  console.log(
    `c0 CPU: ${((100 * used) / ((Date.now() - t0) / 1000)).toFixed(0)}% of one core over ${((Date.now() - t0) / 1000).toFixed(0)} s`,
  );
}
await Promise.all(children.map((c) => new Promise((r) => c.on('exit', r))));
console.log(`Logs in ${logDir}`);
