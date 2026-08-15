# Optional remote access

Cockpit listens through systemd socket activation but Bootsy deliberately does
not expose TCP 9090 through firewalld. Reach it through SSH:

```sh
ssh -L 9090:localhost:9090 your-server
```

Then open `https://localhost:9090`. Node Exporter is installed for monitoring
integrations but is not enabled or exposed by default.

Tailscale is intentionally not baked in from a third-party repository. To opt
in, follow Tailscale's current Fedora instructions, authenticate the machine,
and restrict advertised routes/SSH access to what this host actually needs.
