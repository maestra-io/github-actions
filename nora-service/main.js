// A node action only for its post step (post.js removes the container); the work is bash.
const { spawnSync } = require('child_process');
const r = spawnSync('bash', [`${__dirname}/nora-service.sh`], { stdio: 'inherit' });
process.exitCode = r.status ?? 1;
