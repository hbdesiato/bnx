PROJECT_NAME:=`basename "$PWD"`
PROJECT_REPO:="localhost:5000"
THIS_IMAGE:=PROJECT_REPO+"/"+PROJECT_NAME+"-unsealed"
SEALED_IMAGE:=PROJECT_REPO+"/"+PROJECT_NAME
BASE_IMAGE:="ghcr.io/ublue-os/bluefin-nvidia-open:stable-daily"

build $BUILD_ARGS="" $THIS_IMAGE=THIS_IMAGE $BASE_IMAGE=BASE_IMAGE:
    #!/usr/bin/env bash
    set -euxo pipefail
    podman build ${BUILD_ARGS} \
        --build-arg BASE_IMAGE="${BASE_IMAGE}" \
        --secret=id=secureboot_key,src=keys/db/db.key \
        --secret=id=secureboot_cert,src=keys/db/db.pem \
        -t "${THIS_IMAGE}" .

push $IMAGE=SEALED_IMAGE:
    #!/usr/bin/env bash
    set -euxo pipefail
    DIGEST="${IMAGE##*/}.digest"
    mkdir -p build
    podman push --sign-by-sigstore-private-key keys/sigstore.private --sign-passphrase-file keys/sigstore.passphrase \
        --digestfile="build/${DIGEST}" "${IMAGE}"
    [ "${IMAGE%%/*}" = "ghcr.io" ] || exit 0
    mv build/${DIGEST} ${DIGEST}
    git add "${DIGEST}"
    git commit -m "${IMAGE} pushed"

push-unsealed: (push THIS_IMAGE) 

seal $SEALED_IMAGE=SEALED_IMAGE $THIS_IMAGE=THIS_IMAGE:
    #!/usr/bin/env bash
    set -euxo pipefail
    rm -rf build/chunkah
    mkdir -p build/chunkah
    CONFIG_FILE="build/chunkah/config.json"
    podman inspect $THIS_IMAGE > $CONFIG_FILE

    podman build --build-arg BASE_IMAGE="$THIS_IMAGE" \
        --build-arg CONFIG_FILE="$CONFIG_FILE" \
        -f Containerfile.tbs \
        -t "${THIS_IMAGE}-tbs" .
    
    podman run --rm \
        --security-opt label=disable \
        -v ./build/chunkah:/build \
        "${THIS_IMAGE}-tbs" cp -a /out /build/.

    podman build --build-arg BASE_IMAGE="oci:build/chunkah/out" \
        --build-arg KARGS="quiet rhgb" \
        --security-opt label=disable \
        --secret=id=secureboot_key,src=keys/db/db.key \
        --secret=id=secureboot_cert,src=keys/db/db.pem \
        -f Containerfile.seal \
        -t "${SEALED_IMAGE}" .

build-seal-push $SEALED_IMAGE=SEALED_IMAGE $THIS_IMAGE=THIS_IMAGE $BASE_IMAGE=BASE_IMAGE:
    just build --no-cache "${THIS_IMAGE}" "${BASE_IMAGE}"
    just push "${THIS_IMAGE}"
    just seal "${SEALED_IMAGE}" "${THIS_IMAGE}"
    just push "${SEALED_IMAGE}"

update $SEALED_IMAGE=SEALED_IMAGE $THIS_IMAGE=THIS_IMAGE $BASE_IMAGE=BASE_IMAGE:
    #!/usr/bin/env bash
    set -euxo pipefail
    if just pkgs-check "${THIS_IMAGE}" "${BASE_IMAGE}" && just base-check "${THIS_IMAGE}" "${BASE_IMAGE}"
    then exit 0
    fi
    just build-seal-push "${SEALED_IMAGE}" "${THIS_IMAGE}" "${BASE_IMAGE}"

pkgs-list $IMAGE=BASE_IMAGE:
    podman run --rm "${IMAGE}" rpm -q --qf="%{NAME}\n" -a

pkgs-diff $THIS_IMAGE=THIS_IMAGE $BASE_IMAGE=BASE_IMAGE:
    printf '%s\n%s\n' "$(just pkgs-list "${THIS_IMAGE}")" "$(just pkgs-list "${BASE_IMAGE}")" | sort | uniq -u | tr '\n' ' '

pkgs-check $THIS_IMAGE=THIS_IMAGE $BASE_IMAGE=BASE_IMAGE:
    podman run --rm "${THIS_IMAGE}" dnf check-upgrade $(just pkgs-diff "${THIS_IMAGE}" "${BASE_IMAGE}" | tr '\n' ' ')

base-check $THIS_IMAGE=THIS_IMAGE $BASE_IMAGE=BASE_IMAGE:
    #!/usr/bin/env bash
    set -euxo pipefail
    digest1="$(podman image inspect --format '{{{{index .Annotations "org.opencontainers.image.base.digest"}}' "${THIS_IMAGE}")"
    podman pull "${BASE_IMAGE}"
    digest2="$(podman image ls --format '{{{{.Digest}}' "${BASE_IMAGE}")"
    [ "${digest1}" = "${digest2}" ]

generate-keys $PROJECT_NAME=PROJECT_NAME:
    #!/usr/bin/env bash
    set -euxo pipefail
    [ ! -e keys ] || exit 0
    mkdir -p keys/db
    umask 0077
    <<<"" cat >"keys/sigstore.passphrase"
    skopeo generate-sigstore-key --passphrase-file "keys/sigstore.passphrase" --output-prefix "keys/sigstore"
    openssl genpkey -algorithm rsa -pkeyopt rsa_keygen_bits:4096 -out keys/db/db.key
    openssl x509 -new -key keys/db/db.key -set_subject "/CN=${PROJECT_NAME} secure boot/" -out keys/db/db.pem
    openssl x509 -outform DER -in keys/db/db.pem -out keys/db/db.cer
    uuidgen > keys/GUID

generate-config $PROJECT_REPO=PROJECT_REPO:
    #!/usr/bin/env bash
    set -euxo pipefail
    CONFIG="${HOME}/.config"
    mkdir -p "${CONFIG}/containers/registries.d"
    cat >"${CONFIG}/containers/registries.d/sigstore.yaml" <<EOC
    docker:
        ${PROJECT_REPO}:
            use-sigstore-attachments: true
        ghcr.io/ublue-os:
            use-sigstore-attachments: true
    EOC
    cat "${CONFIG}/containers/registries.d/sigstore.yaml"
    jq >"${CONFIG}/containers/policy.json" <<EOC
    {
        "default": [
            {
                "type": "insecureAcceptAnything"
            }
        ],
        "transports": {
            "docker": {
                "${PROJECT_REPO}": [
                    {
                        "type": "sigstoreSigned",
                        "keyPath": "$(realpath keys/sigstore.pub)",
                        "signedIdentity": {
                            "type": "matchRepository"
                        }
                    }
                ],
                "ghcr.io/ublue-os": [
                    {
                        "type": "sigstoreSigned",
                        "keyPath": "$(realpath keys/ublue-os.pub)",
                        "signedIdentity": {
                            "type": "matchRepository"
                        }
                    }
                ]
            }
        }
    }
    EOC
    cat "${CONFIG}/containers/policy.json"
gh-setup $PROJECT_REPO=PROJECT_REPO:
    #!/usr/bin/env bash
    set -euxo pipefail

    git config --global user.name "github-actions[bot]"
    git config --global user.email "github-actions[bot]@users.noreply.github.com"
    just generate-config "${PROJECT_REPO}"
    umask 0077
    <<<"${SIGSTORE_PRIVATE}" cat >"keys/sigstore.private"
    <<<"" cat >"keys/sigstore.passphrase"
    <<<"${DB_KEY}" cat >keys/db/db.key

INSTALL_DISK_SIZE:="40G"

install $IMAGE=SEALED_IMAGE:
    #!/usr/bin/env bash
    set -euxo pipefail
    NAME="${IMAGE##*/}"
    NAME="${NAME%:*}"
    DISK_IMAGE="qemu/${NAME}.raw"
    EFI_VARS="qemu/${NAME}_VARS.qcow2"
    TPM_DIR="qemu/${NAME}.tpm"
    which virt-fw-vars || uv tool install virt-firmware
    mkdir -p qemu
    chattr +C qemu || true
    rm -f "${DISK_IMAGE}"
    fallocate -l "{{INSTALL_DISK_SIZE}}" "${DISK_IMAGE}"
    rm -f "${EFI_VARS}"
    virt-fw-vars -i /usr/share/edk2/ovmf/OVMF_VARS_4M.secboot.qcow2 -o "${EFI_VARS}" \
        --add-db "$(cat keys/GUID)" keys/db/db.cer
    rm -rf "${TPM_DIR}"
    mkdir -p "${TPM_DIR}"
    sudo podman run --rm --privileged --pid=host \
        --pull=newer \
        -v "./qemu:/qemu" \
        -v /var/lib/containers:/var/lib/containers \
        -v /dev:/dev \
        --security-opt label=type:unconfined_t \
        "${IMAGE}" \
        bootc install to-disk \
        --composefs-backend --bootloader=systemd \
        --filesystem btrfs \
        --via-loopback "/${DISK_IMAGE}"

install-ghcr $IMAGE_NAME=PROJECT_NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_URL="$(git remote get-url origin)"
    REPO_BASE_URL="${REPO_URL%/*}"
    REPO_BASE="${REPO_BASE_URL##*[:/]}"
    just install "ghcr.io/${REPO_BASE}/${IMAGE_NAME}"

install-unsealed $IMAGE=THIS_IMAGE:
    #!/usr/bin/env bash
    set -euxo pipefail
    NAME="${IMAGE##*/}"
    NAME="${NAME%:*}"
    DISK_IMAGE="qemu/${NAME}.raw"
    EFI_VARS="qemu/${NAME}_VARS.qcow2"
    TPM_DIR="qemu/${NAME}.tpm"
    which virt-fw-vars || uv tool install virt-firmware
    mkdir -p qemu
    chattr +C qemu || true
    rm -f "${DISK_IMAGE}"
    fallocate -l "{{INSTALL_DISK_SIZE}}" "${DISK_IMAGE}"
    rm -f "${EFI_VARS}"
    cp /usr/share/edk2/ovmf/OVMF_VARS_4M.qcow2 "${EFI_VARS}"
    rm -rf "${TPM_DIR}"
    mkdir -p "${TPM_DIR}"
    sudo podman run --rm --privileged --pid=host \
        --pull=newer \
        -v "./qemu:/qemu" \
        -v /var/lib/containers:/var/lib/containers \
        -v /dev:/dev \
        --security-opt label=type:unconfined_t \
        "${IMAGE}" \
        bootc install to-disk \
        --filesystem btrfs \
        --via-loopback "/${DISK_IMAGE}"

run $IMAGE=PROJECT_NAME:
    #!/usr/bin/env bash
    set -euxo pipefail
    NAME="${IMAGE##*/}"
    NAME="${NAME%:*}"
    DISK_IMAGE="qemu/${NAME}.raw"
    EFI_VARS="qemu/${NAME}_VARS.qcow2"
    TPM_DIR="qemu/${NAME}.tpm"
    TPM_SOCKET="${TPM_DIR}/swtpm-sock"
    swtpm socket --tpmstate dir="${TPM_DIR}" --ctrl type=unixio,path="${TPM_SOCKET}" --tpm2 &
    qemu-system-x86_64 \
        -enable-kvm \
        -machine q35 \
        -cpu host \
        -smp 8 \
        -m 8G \
        -display gtk,gl=on -device virtio-vga-gl \
        -chardev socket,id=chrtpm,path="${TPM_SOCKET}" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0,id=tpm0 \
        -drive if=pflash,format=qcow2,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE_4M.qcow2 \
        -drive if=pflash,format=qcow2,file="${EFI_VARS}" \
        -drive if=virtio,format=raw,file="${DISK_IMAGE}"

run-unsealed: (run THIS_IMAGE) 

local-registry:
    #!/usr/bin/env bash
    set -euxo pipefail
    [ -e /etc/containers/registries.conf.d/localhost-5000.conf ] || sudo tee /etc/containers/registries.conf.d/localhost-5000.conf <<EOC
    [[registry]]
    location = "localhost:5000"
    insecure = true
    EOC
    [ -e /etc/containers/registries.d/localhost-5000.yaml ] || sudo tee /etc/containers/registries.d/localhost-5000.yaml <<EOC
    docker:
        localhost:5000:
            use-sigstore-attachments: true
    EOC
    podman run --rm --network=pasta:--no-splice -p 127.0.0.1:5000:5000 registry:3

to-disk-partitions:
    #!/usr/bin/env bash
    set -euo pipefail
    PARTS_JSON="$(sudo lsblk -o NAME,PARTTYPE,PARTLABEL,PARTUUID --json | jq '
        .blockdevices[] |
        select(.children != null) |
        select(.children | any(.partlabel == "bootc-TARGET" ) )')"
    <<< "$PARTS_JSON" jq -r '
        .children[] | 
        select(.parttype == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b") |
        "EFI_PART="+.name'
    <<< "$PARTS_JSON" jq -r '
        .children[] | 
        select(.parttype == "4f68bce3-e8cd-4db1-96e7-fbcaf984b709") |
        "ROOT_PART="+.name'
    <<< "$PARTS_JSON" jq -r '
        .children[] | 
        select(.parttype == "4f68bce3-e8cd-4db1-96e7-fbcaf984b709") |
        "ROOT_PART_UUID="+.partuuid'
        

to-disk-luks:
    #!/usr/bin/env bash
    set -euxo pipefail
    eval "$(just to-disk-partitions)"
    KEY_FILE="luks/${ROOT_PART_UUID}.key"
    LUKS_VOL="luks-${ROOT_PART}"
    sudo systemd-cryptsetup detach "${LUKS_VOL}"
    sudo cryptsetup erase "/dev/${ROOT_PART}" || true
    mkdir -p luks
    umask go=
    openssl rand -base64 32 > "${KEY_FILE}"
    sudo cryptsetup luksFormat --pbkdf pbkdf2 -i 1 "/dev/${ROOT_PART}" "${KEY_FILE}"

to-disk-luks-pin:
    #!/usr/bin/env bash
    set -euxo pipefail
    eval "$(just to-disk-partitions)"
    KEY_FILE=$(realpath "luks/${ROOT_PART_UUID}.key")
    sudo systemd-cryptenroll --unlock-key-file "${KEY_FILE}" --tpm2-device auto --tpm2-with-pin true "/dev/disk/by-partuuid/${ROOT_PART_UUID}"

to-disk-luks-qemu:
    #!/usr/bin/env bash
    set -euxo pipefail
    eval "$(just to-disk-partitions)"
    KEY_FILE="luks/${ROOT_PART_UUID}.key"
    sudo cryptsetup luksAddKey --pbkdf pbkdf2 -i 1 -d "${KEY_FILE}" -y --force-password "/dev/${ROOT_PART}" 

to-disk-format:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just to-disk-partitions)"
    if sudo cryptsetup isLuks "/dev/${ROOT_PART}"; then
        LUKS_VOL="luks-${ROOT_PART}"
        KEY_FILE=$(realpath "luks/${ROOT_PART_UUID}.key")
        sudo systemd-cryptsetup attach "${LUKS_VOL}" "/dev/${ROOT_PART}" "${KEY_FILE}"
        ROOT_DEV="/dev/mapper/${LUKS_VOL}"
    else
        ROOT_DEV="/dev/${ROOT_PART}"
    fi
    mkdir -p to-disk/root
    sudo umount -R to-disk/root || true
    sudo mkfs.btrfs -f "${ROOT_DEV}"
    sudo mkfs.fat -F32 "/dev/${EFI_PART}"

to-disk-mount:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just to-disk-partitions)"
    if sudo cryptsetup isLuks "/dev/${ROOT_PART}"; then
        LUKS_VOL="luks-${ROOT_PART}"
        sudo systemd-cryptsetup attach "${LUKS_VOL}" "/dev/${ROOT_PART}"
        ROOT_DEV="/dev/mapper/${LUKS_VOL}"
    else
        ROOT_DEV="/dev/${ROOT_PART}"
    fi
    sudo mount "${ROOT_DEV}" to-disk/root
    sudo mkdir -p to-disk/root/boot
    sudo mount -o umask=0077 "/dev/${EFI_PART}" to-disk/root/boot

to-disk-unmount:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo umount -R to-disk/root || true
    eval "$(just to-disk-partitions)"
    if sudo cryptsetup isLuks "/dev/${ROOT_PART}"; then
        LUKS_VOL="luks-${ROOT_PART}"
        sudo systemd-cryptsetup detach "${LUKS_VOL}"
    fi

install-to-disk $IMAGE_NAME=PROJECT_NAME: to-disk-mount && to-disk-unmount
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_URL="$(git remote get-url origin)"
    REPO_BASE_URL="${REPO_URL%/*}"
    REPO_BASE="${REPO_BASE_URL##*[:/]}"
    IMAGE="ghcr.io/${REPO_BASE}/${IMAGE_NAME}"
    sudo podman run --rm --privileged --pid=host \
        --pull=newer \
        -v /dev:/dev \
        -v "./to-disk/root":/target \
        -v /var/lib/containers:/var/lib/containers \
        --security-opt label=type:unconfined_t \
        "${IMAGE}" \
        bootc install to-filesystem \
        --composefs-backend --bootloader=systemd \
        --skip-finalize \
        /target

loop-setup $IMAGE=PROJECT_NAME: loop-detach
    #!/usr/bin/env bash
    set -euxo pipefail
    NAME="${IMAGE##*/}"
    NAME="${NAME%:*}"
    DISK_IMAGE="qemu/${NAME}.raw"
    rm -f "${DISK_IMAGE}"
    fallocate -l "{{INSTALL_DISK_SIZE}}" "${DISK_IMAGE}"
    <target.sfdisk sfdisk "${DISK_IMAGE}"
    sudo losetup -fP "${DISK_IMAGE}"

loop-detach:
    #!/usr/bin/env bash
    set -euxo pipefail
    eval "$(just to-disk-partitions)"
    [ ! "${TARGET:-}" ] || sudo losetup -d "/dev/${TARGET}"
