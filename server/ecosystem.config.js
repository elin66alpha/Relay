module.exports = {
  apps: [
    {
      name: 'agentdeck-server',
      script: 'server.js',
      env_file: '.env',
      restart_delay: 5000,
      max_restarts: 10,
    },
    {
      name: 'agentdeck-tunnel',
      script: process.env.CLOUDFLARED_BIN || 'cloudflared',
      interpreter: 'none',
      args: 'tunnel --url http://localhost:8787',
      restart_delay: 5000,
      max_restarts: 50,
    },
  ],
};
