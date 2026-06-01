# Local test target — an Ubuntu 22.04 container that runs systemd, lets us
# SSH in as the rc user, and stands in for an EC2 instance. Exercises the
# bootstrap-host.sh + deploy.sh pipeline without needing AWS access.
#
# NOT for production. Privileged systemd-in-Docker is a development affordance.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# Pre-install everything bootstrap-host.sh would install. Saves ~3 min of
# apt every time we re-run the local test. bootstrap-host.sh is idempotent
# so it just notices the packages are already there.
#
# awscli is intentionally omitted — local tests use RC_SECRET_FILE mode
# and shouldn't touch AWS.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      systemd systemd-sysv \
      openssh-server sudo \
      nginx \
      postgresql postgresql-contrib \
      jq curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Pre-create the rc user so SSH lands as that user immediately. bootstrap-host.sh
# is idempotent w.r.t. user creation.
RUN useradd -m -u 1001 -s /bin/bash rc \
 && install -d -o rc -g rc -m 0700 /home/rc/.ssh

# The authorized_keys file is bind-mounted at run time so we don't bake a
# secret into the image. See run-local-test.sh.

# sshd needs this dir on Ubuntu.
RUN mkdir -p /run/sshd

# Drop the systemd default-target generator goo that fights our --privileged
# launch in some Docker setups.
RUN systemctl set-default multi-user.target

EXPOSE 22 80
STOPSIGNAL SIGRTMIN+3

CMD ["/sbin/init"]
