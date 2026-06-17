ARG BASE_IMAGE
FROM $BASE_IMAGE
COPY keys/sigstore.pub /usr/lib/pki/containers/bnx.pub
RUN \
    --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=tmpfs,target=/var \
<<EORUN
cat >/etc/containers/registries.d/bnx.yaml <<EOC
docker:
    ghcr.io/hbdesiato/bnx:
        use-sigstore-attachments: true
EOC
set -euxo pipefail
jq \
    --arg registry "ghcr.io/hbdesiato/bnx" \
    --arg keypath "/usr/lib/pki/containers/bnx.pub" \
    '.transports.docker[$registry] = [
        {
            "type": "sigstoreSigned",
            "keyPath": $keypath
        }
    ]' /etc/containers/policy.json >/etc/containers/policy.new.json
mv /etc/containers/policy.new.json /etc/containers/policy.json
dnf -y install niri mako swaybg swayidle polkit-kde kf6-kirigami udiskie \
    libappindicator-gtk3 brightnessctl pavucontrol blueman network-manager-applet \
    qemu-system-x86 qemu-img
EORUN
COPY sysconfig /
