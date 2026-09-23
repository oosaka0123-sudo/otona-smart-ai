# 大人のスマホAI生活

YouTube「大人のスマホAI生活」と連動し、スマホとAIをやさしく学べる情報サイトです。

## URLs

- Production: https://sumaho.rss7.net/ （Lolipop / planned until live verification）
- Preview / fallback: https://oosaka0123-sudo.github.io/otona-smart-ai/

## Deployment

GitHub is the source of truth. Production deployment uses GitHub Actions + lftp over FTPS.

Required repository secrets:

- `LOLIPOP_FTP_SERVER`
- `LOLIPOP_FTP_USERNAME`
- `LOLIPOP_FTP_PASSWORD`
- `LOLIPOP_FTP_SERVER_DIR` — must be exactly `/sumaho`

The production workflow is manual-only until the Lolipop subdomain and secrets are configured and live verification succeeds.
