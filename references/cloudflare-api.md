# Cloudflare API v4: what this guide uses (R18)

Base: `https://api.cloudflare.com/client/v4` (`CF_API` in `lib.sh` overrides it for the tests),
header `Authorization: Bearer <token>`. Use `cfapi`, `cf_check`, `dns_set_a` and `dns_list` from
`lib.sh`; nothing else in the guide calls Cloudflare.

**Status:** written from the Cloudflare API documentation (developers.cloudflare.com) and tested
against a fake API only (`test/lib.test.sh`). **Not run against the real Cloudflare API yet.**
"docs" below means taken from the documentation, not seen in a live answer; every line is
**[verify]** until the first run on a Cloudflare-managed test domain. **[assumed]** means not in
the documentation either: our reading, to be confirmed or corrected on that run.

## Token

One **user API token** from the **Edit zone DNS** template (My Profile → API Tokens), Zone
Resources = that one zone. It can change DNS of that zone and nothing else in the account. It
lives in `~/.config/vps-setup/cloudflare.env` as `CF_API_TOKEN=...`, mode 600, typed in by the
user (phase 00, step 4a). `lib.sh` reads it with `grep | cut`, never sources the file, and gives
it to curl in a config on stdin (`curl -K -`), so it is never on a command line. A token with
characters other than letters, digits, `-` and `_` is refused before any call (it could break
curl's config syntax).

## Calls

| Call | Use | Source |
|------|-----|--------|
| every answer | `{success, errors:[{code, message}], messages, result}`; `cfapi` checks `success` and prints `code: message` per error, never the raw body | docs |
| `GET /user/tokens/verify` | `cf_check`: `result.status` is `active`, `disabled` or `expired` | docs |
| same, with a bad token | HTTP 401, error `1000: Invalid API Token` (the fake answers this way) | [assumed] |
| `GET /zones?name=<zone>` | `cf_check`: `result[].id`, `name`, `status` (`pending` until the name servers are Cloudflare's); tried from the full `DOMAIN` down, the longest suffix that is a zone wins | docs |
| `GET /zones` with an Edit-zone-DNS-only token | lists the token's own zone (certbot-dns-cloudflare relies on the same) | [assumed] |
| `GET /zones/{zone}/dns_records?name=<fqdn>&per_page=100` | every record of exactly that name (`name` is an exact match) | docs |
| `POST /zones/{zone}/dns_records` | body `{type:"A", name, content, ttl:1, proxied:false, comment:"vps-setup"}`; `ttl: 1` means automatic | docs |
| `PATCH /zones/{zone}/dns_records/{id}` | partial update, body `{content, proxied:false}` | docs |
| zone and record ids | 32 lower-case hex characters; `lib.sh` refuses anything else before putting it into a path | [assumed], from the docs' examples |
| a second identical record | an error (`81057`, "record already exists") | [assumed]; `dns_set_a` never hits it, it reads the name first |

`lib.sh` never sends `DELETE`. A record that is in the way (a CNAME, a second A, an AAAA) is
named and the user deletes it in the dashboard (DNS → Records); teardown lists records with
`dns_list` and the user deletes them.

## Rules the helpers follow

- **A/AAAA and CNAME cannot share a name** (docs). `dns_set_a` refuses a name with a CNAME and
  sends nothing.
- **No AAAA next to the A** (phase 01): the guide records only the server's IPv4 address, and an
  AAAA left over (a registrar's parking page, an old server) sends IPv6 visitors and Let's Encrypt
  somewhere else. `dns_set_a` sets the A record, then warns and returns 2.
- **Always `proxied: false`** (DNS only, grey cloud). [assumed]: with the orange cloud,
  Cloudflare terminates TLS in front of the server, so Traefik's HTTP-01 challenge and the
  origin's Let's Encrypt certificate stop being what visitors see, and "Flexible" SSL loops
  redirects (`references/troubleshooting.md`). Phase 01 already asks for DNS only; a proxied A
  record found by `dns_set_a` is switched to DNS only and the output says so.
- **Rate limit:** 1,200 requests per 5 minutes per user; above it HTTP 429 (docs). `cfapi` says
  so and stops; the error code in the 429 body (`971` in the fake) is [assumed] and not relied on.
  One `dns_set_a` is two calls, `cf_check` at most one per label of `DOMAIN` plus one.
