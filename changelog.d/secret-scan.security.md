- security: secrets are recognised by content, in one detector in the engine (#45):
  - tokens of GitHub, GitLab, Slack, AWS, npm and Azure DevOps, `sk-` API keys and JSON web tokens;
  - private keys, credentials in URLs and authorization headers;
  - passwords, and random-looking values under secret-like keys.

  The run log and error messages mask whatever it finds. The repository inventory leaves out a setting that holds a secret, and records a remote URL without the secret in it
