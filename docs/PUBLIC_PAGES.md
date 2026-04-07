# Public Pages

This document is for the small set of public pages that support App Store submission and user support.

Apple requires a public privacy-policy URL for App Store submissions.

## Repo Source Of Truth

- `docs/index.html`
- `docs/privacy-policy.html`
- `docs/support.html`

## Deploy Workflow

- `.github/workflows/deploy-privacy-policy.yml`

## Expected Public URLs

After GitHub Pages is enabled for this repository:

- Site: `https://vemundss.github.io/MOBaiLE/`
- Privacy policy: `https://vemundss.github.io/MOBaiLE/privacy-policy.html`
- Support: `https://vemundss.github.io/MOBaiLE/support.html`

## Activation Steps

1. Push `main` to GitHub.
2. In GitHub repository settings, enable Pages and select `GitHub Actions` as the source.
3. Wait for the `Deploy Public Pages` workflow to complete.
4. Use the GitHub Pages URLs in App Store Connect and inside the app once they are live.
5. If you rename the repo or move it to another owner, update the URLs accordingly.
