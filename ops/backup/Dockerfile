# The backup producer: pg_dump, gpg and an S3 client, and nothing else.
#
# Based on the official postgres image for one reason: pg_dump must be at least
# the server's major version, and the previous incarnation of this job spent
# three steps installing PostgreSQL 17 from the pgdg apt repository on every
# run -- one more piece of someone else's infrastructure in the nightly path.
# Here the client comes with the base image.
#
# Pinned by digest, not by tag. This container holds the database credentials
# and the Tigris keys; a tag that moves would change what runs with them. Bump
# deliberately:
#
#   ops/backup/refresh-digest.sh      prints the current digest for 17-bookworm
#
# Debian rather than Alpine deliberately: scripts/check-toolchain.sh requires
# any `FROM alpine:` to use the release's pinned ALPINE_VERSION, which belongs
# to the Elixir builder and has nothing to do with this image.
FROM postgres:17-bookworm@sha256:639ab7ceb90e13123085b741fb31ef493fba25463002f6da665352e7b534b652

# awscli speaks to any S3-compatible endpoint, so the destination is a
# configuration detail rather than a dependency. gnupg encrypts; coreutils
# provides shred, which the script uses to remove the plaintext dump.
RUN apt-get update \
 && apt-get install -y --no-install-recommends awscli gnupg ca-certificates coreutils curl \
 && rm -rf /var/lib/apt/lists/*

COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

# Not the postgres server. This image runs one command and exits, and its exit
# status is the whole result.
ENTRYPOINT ["/usr/local/bin/backup.sh"]
