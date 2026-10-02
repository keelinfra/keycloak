# syntax=docker/dockerfile:1
# Images for the 3-node container rig (dev/ha-up.sh, dev/containers/README.md).
# Built locally or inside the CI job, tagged kc-ha-*:local, never pushed.
#
#   node    — a cluster node: what the Ubuntu 24.04 cloud image ships and the
#             roles rely on, plus systemd as PID 1 and an sshd (Ansible and
#             the pgBackRest mesh come in over ssh, as on VMs). Nothing the
#             roles install themselves is pre-baked: every run is a clean
#             install.
#   control — the operator's machine: ansible-core in a venv plus the
#             collections from requirements.yml, so ./configure, ./install,
#             ./upgrade and ./verify run unchanged.

ARG UBUNTU_TAG=24.04

FROM ubuntu:${UBUNTU_TAG} AS node
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus \
      openssh-server sudo cron \
      python3 python3-apt python3-debian python3-cryptography \
      ca-certificates curl gnupg iproute2 procps tar \
 && rm -rf /var/lib/apt/lists/*
# The base image stops apt from starting services; a VM does not.
RUN rm -f /usr/sbin/policy-rc.d
# Three chronyd with CAP_SYS_TIME would all step the host's clock. The common
# role installs chrony but, in container mode, does not start it; the mask
# keeps the package postinst from starting it either.
RUN systemctl mask chrony.service
# Plain sshd rather than socket activation, so the healthcheck can watch the
# unit; host keys are generated at first boot so the three nodes differ.
RUN systemctl enable ssh.service \
 && systemctl disable ssh.socket \
 && rm -f /etc/ssh/ssh_host_*
COPY dev/containers/ssh-hostkeys.service /etc/systemd/system/ssh-hostkeys.service
RUN mkdir -p /etc/systemd/system/ssh.service.d \
 && printf '[Unit]\nWants=ssh-hostkeys.service\nAfter=ssh-hostkeys.service\n' \
      > /etc/systemd/system/ssh.service.d/hostkeys.conf
# Cloud-image conventions ./configure relies on: user ubuntu, passwordless sudo.
RUN (id ubuntu >/dev/null 2>&1 || useradd -m ubuntu) \
 && usermod -s /bin/bash ubuntu \
 && echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-ubuntu \
 && chmod 440 /etc/sudoers.d/90-ubuntu
# Empty machine-id: systemd generates one per container at first boot.
RUN : > /etc/machine-id && rm -f /var/lib/dbus/machine-id
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]

FROM ubuntu:${UBUNTU_TAG} AS control
ARG ANSIBLE_CORE_SPEC=ansible-core
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-venv openssh-client openssl ca-certificates curl jq socat \
 && rm -rf /var/lib/apt/lists/*
COPY requirements.yml /tmp/requirements.yml
# ansible.cfg sets collections_path = ~/.ansible/collections; install there
# so ./configure's `ansible-galaxy collection install` finds them satisfied.
RUN python3 -m venv /opt/ansible \
 && /opt/ansible/bin/pip install --no-cache-dir "${ANSIBLE_CORE_SPEC}" \
 && /opt/ansible/bin/ansible-galaxy collection install -r /tmp/requirements.yml \
      -p /root/.ansible/collections \
 && rm /tmp/requirements.yml
ENV PATH=/opt/ansible/bin:$PATH
WORKDIR /work
CMD ["sleep", "infinity"]
