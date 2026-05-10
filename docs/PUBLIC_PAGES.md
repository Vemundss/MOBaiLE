# Public Pages

This document is for the small set of public pages that support App Store submission and user support.

Apple requires a public privacy-policy URL for App Store submissions.

## Repo Source Of Truth

- `docs/index.html`
- `docs/codex-from-iphone.html`
- `docs/claude-code-from-iphone.html`
- `docs/self-hosted-iphone-agent.html`
- `docs/tailscale-iphone-agent.html`
- `docs/safe-vs-full-access.html`
- `docs/trust.html`
- `docs/privacy-policy.html`
- `docs/support.html`
- `docs/robots.txt`
- `docs/sitemap.xml`
- `docs/llms.txt`

## Deploy Workflow

- `.github/workflows/deploy-public-pages.yml`

## Expected Public URLs

After GitHub Pages is enabled for this repository:

- Site: `https://vemundss.github.io/MOBaiLE/`
- Codex from iPhone: `https://vemundss.github.io/MOBaiLE/codex-from-iphone.html`
- Claude Code from iPhone: `https://vemundss.github.io/MOBaiLE/claude-code-from-iphone.html`
- Self-hosted iPhone agent: `https://vemundss.github.io/MOBaiLE/self-hosted-iphone-agent.html`
- Tailscale iPhone agent: `https://vemundss.github.io/MOBaiLE/tailscale-iphone-agent.html`
- Safe mode vs full access: `https://vemundss.github.io/MOBaiLE/safe-vs-full-access.html`
- Trust model: `https://vemundss.github.io/MOBaiLE/trust.html`
- Privacy policy: `https://vemundss.github.io/MOBaiLE/privacy-policy.html`
- Support: `https://vemundss.github.io/MOBaiLE/support.html`
- Robots: `https://vemundss.github.io/MOBaiLE/robots.txt`
- Sitemap: `https://vemundss.github.io/MOBaiLE/sitemap.xml`
- LLM summary: `https://vemundss.github.io/MOBaiLE/llms.txt`

## Activation Steps

1. Push `main` to GitHub.
2. In GitHub repository settings, enable Pages and select `GitHub Actions` as the source.
3. Wait for the `Deploy Public Pages` workflow to complete.
4. Use the GitHub Pages URLs in App Store Connect and inside the app once they are live.
5. Submit `https://vemundss.github.io/MOBaiLE/sitemap.xml` directly in Google Search Console and Bing Webmaster Tools.
6. If you rename the repo or move it to another owner, update the URLs accordingly.

## Project-Site Robots Note

`docs/robots.txt` is published at `https://vemundss.github.io/MOBaiLE/robots.txt` for visibility and crawler policy documentation. Standard `robots.txt` discovery happens at the domain root, so full robots control for `vemundss.github.io` would require a root/user GitHub Pages site or a custom domain. Until then, submit the sitemap directly in webmaster tools.
