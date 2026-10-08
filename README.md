# pterodactyl-stalwart

[Stalwart](https://stalw.art) mail server (SMTP, submission, IMAP, JMAP and a web admin, one binary) packaged for Pterodactyl.

- Image: `ghcr.io/ddatunashvili/pterodactyl-stalwart:latest` (also `sha-<commit>`), built from `stalwartlabs/stalwart:v0.16.25`
- Egg: `egg-stalwart-mail.json`

Every push to `main` builds the image, boots it the way Wings does (uid 988, Wings' dropped capabilities, `no-new-privileges`, a tty, a banner-prefixed startup line), checks that SMTP, submission, submissions, IMAPS and the web admin all answer and that the administrator login works and a wrong password does not, stops it, starts it again on the same volume, and only then publishes.

## What the container does

| Step | |
| --- | --- |
| First start | Writes `/home/container/etc/config.json` pointing Stalwart at RocksDB in `/home/container/data`. Never rewritten afterwards. |
| Listener setup | Stalwart's defaults are ports 25/465/993/443, which a Wings container cannot bind. Before the real start the entrypoint boots Stalwart once in recovery mode and creates its listeners on this server's allocations over JMAP. Repeated only when the ports change (`/home/container/etc/.renode-listeners`); listeners added in the web admin under other names are kept. |
| Start | Runs the egg's startup command and prints `Renode: Stalwart is ready` once every port answers; that is the egg's "started" line. |
| Login | Web admin user `admin`, password `MAIL_ADMIN_PASSWORD` (generated per server by the shop). It is read from the environment on every start. |

Everything Stalwart stores (settings, mail, DKIM keys, logs) is under `/home/container`.

## Ports

| Variable | Default | Protocol |
| --- | --- | --- |
| `SERVER_PORT` (primary allocation) | — | SMTP (inbound, STARTTLS) |
| `SUBMISSION_PORT` | 2587 | Submission, STARTTLS (standard 587) |
| `SUBMISSIONS_PORT` | 2465 | Submission, implicit TLS (standard 465) |
| `IMAPS_PORT` | 2993 | IMAP, implicit TLS (standard 993) |
| `WEB_PORT` | 2080 | Web admin, JMAP, webmail — plain HTTP; front it with a reverse proxy for HTTPS |

TLS uses a self-signed certificate until one is configured in the web admin (ACME, or upload).

## Receiving mail from the internet

Other mail servers deliver to **port 25** and nothing else. A Wings container cannot listen there, so the node forwards it to the server's SMTP allocation. One mail server per public IP — port 25 on an address can go to one place.

```bash
# on the node, as root: public 25 on 203.0.113.10 -> the SMTP allocation 25724
iptables -t nat -A PREROUTING -d 203.0.113.10 -p tcp --dport 25 -j DNAT --to-destination 203.0.113.10:25724
# make it permanent with iptables-persistent / netfilter-persistent save
```

The same works for 587, 465 and 993 if clients must use the standard ports.

DNS, for a domain `example.com` with the server at `mail.example.com`:

| Record | Value |
| --- | --- |
| `A mail.example.com` | the node's IP |
| `MX example.com` | `10 mail.example.com` |
| `TXT example.com` (SPF) | `v=spf1 mx -all` |
| `TXT <selector>._domainkey.example.com` (DKIM) | from the web admin, after adding the domain |
| `TXT _dmarc.example.com` (DMARC) | `v=DMARC1; p=quarantine; rua=mailto:postmaster@example.com` |
| PTR for the node IP | `mail.example.com` — set at the hosting provider, not in your DNS |

Set **Mail Hostname** to the same name as the PTR record.

**Sending:** many providers block outbound port 25 from servers, and a new IP has no reputation, so direct delivery often fails or lands in spam. Configure a relay (smarthost) in the web admin — your provider's relay, or a service such as Amazon SES, Mailgun, Postmark or SMTP2GO — and outbound mail goes through it.

## Build locally

```bash
docker build -t pterodactyl-stalwart .
```
