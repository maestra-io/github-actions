// Runs after the job's steps whatever their result: the container nora-service.sh started goes.
const { spawnSync } = require('child_process');
const id = process.env.STATE_id;
if (id) spawnSync('docker', ['rm', '-f', '-v', id], { stdio: 'inherit' });
