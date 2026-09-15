# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately, through GitHub's
[private vulnerability reporting](https://github.com/kitplummer/lowendinsight/security/advisories/new),
rather than in a public issue.

## Supported versions

| | Supported |
|---|---|
| Hex package 0.9.2 and later | yes |
| Hex package 0.9.1 and earlier | no -- affected by the report configuration exposure fixed in 0.9.2 |
| The LowEndInsight service, built from this repository | current `main` only |

## Running the service from source

- Set `LEI_SESSION_SECRET` (at least 64 bytes) and `LEI_JWT_SECRET` to unique
  values. A production release refuses to start without them. Never deploy
  with the development defaults in `config/config.exs`.
- The JWTs in this repository's tests and Postman collections are signed with
  the development default secret, and are accepted by any deployment still
  using it.

## Advisories

Published advisories are listed at
https://github.com/kitplummer/lowendinsight/security/advisories.
