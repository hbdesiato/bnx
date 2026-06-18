cat > "/usr/lib/dracut/dracut.conf.d/20-omit-extra-drivers.conf" << 'EOF'
omit_drivers+=" nvidia nvidia_drm nvidia_modeset nvidia_peermem nvidia_uvm v4l2loopback "
EOF

rm -f /usr/lib/dracut/dracut.conf.d/99-nvidia.conf

cat > "/usr/lib/dracut/dracut.conf.d/59-nsswitch.conf" << 'EOF'
install_items+=" /etc/nsswitch.conf "
EOF
