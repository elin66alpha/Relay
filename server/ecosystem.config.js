// AgentDeck backend process, managed by PM2.
//
// Networking is handled by Tailscale, not a bundled tunnel: the backend is
// reached over your private tailnet at a stable MagicDNS address (see setup.sh
// and the README). There is intentionally no public-tunnel process here.
module.exports = {
  apps: [
    {
      name: 'agentdeck-server',
      script: 'server.js',
      env_file: '.env',
      restart_delay: 5000,
      max_restarts: 10,
    },
  ],
};
