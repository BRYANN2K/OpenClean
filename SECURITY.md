# Security Policy

OpenClean deletes files and can run one command as root (after the macOS administrator prompt), so we
treat the following as security issues:

- Any way to make OpenClean remove a file inside the deny-list, outside a rule's folder, or through a
  symlink.
- Any way to influence the command run with administrator privileges (for example through a crafted
  file name).
- A rule pack that passes `openclean rules lint` but targets user data.

Please report privately via GitHub: **Security → Report a vulnerability** on
https://github.com/leoAnimesh/OpenClean. Do not open a public issue. We aim to reply within 7 days.
