// Tiny local media server for the wallpaper skin.
//
// Why a server at all: the ChatGPT desktop app runs as an Isolated Web App on
// app://, and <video src="file:///..."> is blocked. Serving the file over
// http://127.0.0.1 gives the page something it can actually load, and lets us
// answer Range requests so a 100+ MB clip starts playing immediately instead of
// being downloaded in full first.
//
// Usage: node serve.cjs [--port 8756] [--config config.json]
const http = require('http');
const fs = require('fs');
const path = require('path');

const argv = process.argv.slice(2);
const opt = (name, def) => {
  const i = argv.indexOf('--' + name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : def;
};
const CONFIG_PATH = opt('config', path.join(__dirname, 'config.json'));
const config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8').replace(/^\uFEFF/, ''));
const PORT = Number(opt('port', config.mediaPort || 8756));
const VIDEO = config.videoPath;
const LOG_FILE = path.join(__dirname, 'media.log');

function log(msg) {
  const line = new Date().toISOString().slice(11, 19) + ' ' + msg;
  if (process.env.WESKIN_VERBOSE) console.log(line);
  try {
    if (fs.existsSync(LOG_FILE) && fs.statSync(LOG_FILE).size > 512 * 1024) fs.truncateSync(LOG_FILE, 0);
    fs.appendFileSync(LOG_FILE, line + '\n');
  } catch (e) {
    /* logging must never break playback */
  }
}

const MIME = {
  '.mp4': 'video/mp4',
  '.m4v': 'video/mp4',
  '.webm': 'video/webm',
  '.mov': 'video/quicktime',
  '.mkv': 'video/x-matroska',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.webp': 'image/webp',
};

if (!VIDEO || !fs.existsSync(VIDEO)) {
  console.error('video not found: ' + VIDEO + '\nEdit config.json (videoPath) or re-run install.ps1.');
  process.exit(1);
}

const stat = fs.statSync(VIDEO);
const type = MIME[path.extname(VIDEO).toLowerCase()] || 'application/octet-stream';

function cors() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'range,content-type',
    'Access-Control-Allow-Methods': 'GET,HEAD,OPTIONS',
    'Access-Control-Expose-Headers': 'content-length,content-range,accept-ranges',
  };
}

const server = http.createServer((req, res) => {
  const url = (req.url || '/').split('?')[0];

  if (req.method === 'OPTIONS') {
    res.writeHead(204, cors());
    return res.end();
  }

  if (url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json', ...cors() });
    return res.end(JSON.stringify({ ok: true, video: path.basename(VIDEO), bytes: stat.size, type }));
  }

  if (url !== '/wall' && url !== '/wall.mp4') {
    res.writeHead(404, cors());
    return res.end('not found');
  }

  const range = req.headers.range;
  if (range) {
    const m = /bytes=(\d*)-(\d*)/.exec(range);
    let start = m && m[1] ? parseInt(m[1], 10) : 0;
    let end = m && m[2] ? parseInt(m[2], 10) : stat.size - 1;
    if (!m || Number.isNaN(start) || Number.isNaN(end) || start > end || start >= stat.size) {
      res.writeHead(416, { 'Content-Range': `bytes */${stat.size}`, ...cors() });
      return res.end();
    }
    end = Math.min(end, stat.size - 1);
    res.writeHead(206, {
      'Content-Type': type,
      'Content-Length': end - start + 1,
      'Content-Range': `bytes ${start}-${end}/${stat.size}`,
      'Accept-Ranges': 'bytes',
      'Cache-Control': 'no-store',
      ...cors(),
    });
    const stream = fs.createReadStream(VIDEO, { start, end });
    stream.on('error', () => res.destroy());
    return stream.pipe(res);
  }

  res.writeHead(200, {
    'Content-Type': type,
    'Content-Length': stat.size,
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'no-store',
    ...cors(),
  });
  if (req.method === 'HEAD') return res.end();
  const stream = fs.createReadStream(VIDEO);
  stream.on('error', () => res.destroy());
  stream.pipe(res);
});

server.on('error', (e) => {
  console.error('listen failed on ' + PORT + ': ' + e.message);
  process.exit(1);
});

server.listen(PORT, '127.0.0.1', () => {
  log(`serving ${VIDEO} (${stat.size} bytes) on http://127.0.0.1:${PORT}/wall`);
});
