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
    qemu-system-x86 qemu-img \
    tpm2-pkcs11-tools tpm2-pkcs11 tpm2-tools \
    systemd-boot-unsigned sbsigntools systemd-ukify chunkah
dnf -y upgrade bootc
EORUN
COPY sysconfig /
RUN \
    --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=tmpfs,target=/var \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert \
<<EORUN
set -euxo pipefail

mkdir -p /usr/local/bin /usr/local/etc /usr/local/games /usr/local/include \
    /usr/local/lib /usr/local/sbin /usr/local/share /usr/local/src
sed -i 's| /root| /var/roothome|g' /usr/lib/tmpfiles.d/*.conf
sed -i 's| /home| /var/home|g' /usr/lib/tmpfiles.d/*.conf
sed -i 's| /srv| /var/srv|g' /usr/lib/tmpfiles.d/*.conf

sbsign \
  --key /run/secrets/secureboot_key \
  --cert /run/secrets/secureboot_cert \
  /usr/lib/systemd/boot/efi/systemd-bootx64.efi

semodule -i /usr/lib/bnx-tpm2-setup.cil

kver=$(ls /usr/lib/modules)

rm -f /etc/httpd/logs
rm -f /etc/httpd/state
rm -rf /var/cache
bootc container lint
EORUN
