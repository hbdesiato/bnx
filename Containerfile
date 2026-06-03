ARG BASE_IMAGE
FROM $BASE_IMAGE
RUN \
    --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=tmpfs,target=/var \
set -euxo pipefail; \
dnf -y install niri mako swaybg swayidle polkit-kde kf6-kirigami udiskie libappindicator-gtk3 brightnessctl pavucontrol blueman network-manager-applet
COPY sysconfig /
